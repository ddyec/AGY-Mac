"""Session-scoped AI build dispatch. Pull-only devices; never retry an admitted build."""
import json
import os
from pathlib import Path
import secrets
import socketserver
import tempfile
import threading
import time
import uuid

class HybridError(ValueError): pass

class HybridBroker:
    def __init__(self, gateway, timeout=1200, lease=30):
        self.gateway, self.timeout, self.lease = gateway, timeout, lease
        self.lock = threading.RLock(); self.devices = {}; self.jobs = {}; self.contexts = {}
        self.directory = tempfile.TemporaryDirectory(prefix='agy-build-')
        self.path = str(Path(self.directory.name)/'tool.sock')
        broker = self
        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                try:
                    self.connection.settimeout(broker.timeout+30)
                    data = self.rfile.readline(65537)
                    if len(data)>65536: raise HybridError('Request too large')
                    value=json.loads(data); result=broker.tool(value['token'],value['operation'],value.get('arguments',{}))
                except Exception as e: result={'error': str(e) if isinstance(e,HybridError) else 'Build bridge unavailable'}
                self.wfile.write(json.dumps(result,ensure_ascii=False).encode()+b'\n')
        class Server(socketserver.ThreadingUnixStreamServer): daemon_threads=True
        self.server=Server(self.path,Handler); os.chmod(self.path,0o600)
        threading.Thread(target=self.server.serve_forever,daemon=True).start()

    def begin(self, sid, review_token):
        token=secrets.token_urlsafe(32); file=Path(self.directory.name)/(str(uuid.uuid4())+'.json')
        with self.lock: self.contexts[token]=(sid,review_token,file)
        file.write_text(json.dumps({'socket':self.path,'token':token})); file.chmod(0o600)
        return token,file

    def finish(self, token):
        with self.lock:
            context=self.contexts.pop(token,None)
            if context:
                context[2].unlink(missing_ok=True)
                for job in self.jobs.values():
                    if job['_token']==token and job['state'] in ('queued','running'):
                        job.update(state='cancelled',error='AI turn stopped; do not retry automatically')

    def cancel(self, sid):
        with self.lock: tokens=[t for t,c in self.contexts.items() if c[0]==sid]
        for token in tokens:self.finish(token)

    def register(self, sid, body):
        self.gateway.get(sid)
        device=body.get('deviceID'); tools=body.get('tools',[])
        try: uuid.UUID(device)
        except (ValueError,TypeError,AttributeError): raise HybridError('Invalid device ID')
        if body.get('platform')!='macos' or body.get('architecture')!='x86_64':raise HybridError('Expected Intel Mac')
        if not isinstance(tools,list) or len(tools)>20 or any(t not in ('swift','xcodebuild','clang','cmake','node','npm','dotnet','cargo','python3','make') for t in tools):raise HybridError('Invalid toolchains')
        with self.lock:
            self.devices[(sid,device)]={'deviceID':device,'platform':'macos','architecture':'x86_64','tools':tools,'seen':time.monotonic()}
        return {'registered':True,'accountProfile':self.gateway.account_profile}

    def inspect(self,sid):
        cwd=Path(self.gateway.get(sid)['cwd']); hints=[]
        if (cwd/'Package.swift').is_file() or any(cwd.glob('*.xcodeproj')) or any(cwd.glob('*.xcworkspace')):hints.append('macos')
        if (cwd/'package.json').is_file():hints.append('server-web (unless Electron/macOS native packaging is requested)')
        if (cwd/'CMakeLists.txt').is_file() or (cwd/'Cargo.toml').is_file():hints.append('server by default; macos for Apple targets')
        with self.lock: devices=[{k:v for k,v in d.items() if k!='seen'} for (s,_),d in self.devices.items() if s==sid and time.monotonic()-d['seen']<15]
        return {'devices':devices,'projectHints':hints,'server':{'platform':'linux','architecture':os.uname().machine},'policy':'Use the server native terminal for web/Linux tasks. Use build for macOS targets; inspect manifests and user intent, not filename alone. Never claim a missing toolchain or offline device is available.'}

    def tool(self,token,operation,args):
        with self.lock: context=self.contexts.get(token)
        if not context:raise HybridError('Expired AI turn')
        sid,review_token,_=context
        if operation=='inspect':return self.inspect(sid)
        if operation!='build':raise HybridError('Unknown build operation')
        command=args.get('command'); artifacts=args.get('artifacts',[]); subdir=args.get('subdirectory','.')
        if not isinstance(command,str) or not command.strip() or len(command.encode())>16000:raise HybridError('Invalid build command')
        if not isinstance(artifacts,list) or len(artifacts)>7:raise HybridError('At most 7 artifact paths')
        for p in [subdir]+artifacts:
            if not isinstance(p,str) or not p or p.startswith(('/', '~')) or '\\' in p or '..' in Path(p).parts or '\0' in p:raise HybridError('Paths must be project-relative without parent traversal')
        devices=self.inspect(sid)['devices']
        if not devices:raise HybridError('No online Mac for this conversation. Open the Mac app and enable AI builds; do not substitute a server build for an Apple target.')
        device=devices[0]['deviceID']; session=self.gateway.get(sid)
        if session.get('approvalMode')!='turbo':
            if not self.gateway.review or not review_token:raise HybridError('Approval service unavailable')
            decision=self.gateway.review.wait(review_token,{'toolCall':{'name':'macos_build','args':{'command':command,'subdirectory':subdir,'artifacts':artifacts,'device':'Intel Mac'}}})
            if decision!='allow':raise HybridError('Build denied or approval expired')
        with self.lock:
            if token not in self.contexts:raise HybridError('AI turn ended')
            if any(j['deviceID']==device and j['state'] in ('queued','running') for j in self.jobs.values()):raise HybridError('Mac busy; wait for the existing build')
            if len(self.jobs)>200:
                self.jobs={k:j for k,j in self.jobs.items() if j['state'] in ('queued','running')}
            jid=str(uuid.uuid4()); job={'id':jid,'sessionID':sid,'deviceID':device,'command':command,'subdirectory':subdir,'artifacts':artifacts,'state':'queued','deadline':time.time()+self.timeout,'_token':token,'_lease':time.monotonic()+self.lease}
            self.jobs[jid]=job
        while True:
            with self.lock:
                if job['state'] not in ('queued','running'):return {k:v for k,v in job.items() if not k.startswith('_')}
                if time.time()>job['deadline'] or time.monotonic()>job['_lease']:
                    job.update(state='failed',error='Mac disconnected or timed out; execution may have started. Not retried.');continue
            time.sleep(.2)

    def poll(self,device):
        with self.lock:
            for (sid,did),d in self.devices.items():
                if did==device:d['seen']=time.monotonic()
            for j in self.jobs.values():
                if j['deviceID']==device and j['state']=='queued':
                    if time.monotonic()>j['_lease'] or time.time()>j['deadline']:j.update(state='failed',error='Dispatch expired');continue
                    j.update(state='running',_nonce=secrets.token_urlsafe(24),_lease=time.monotonic()+self.lease)
                    return {'job':{k:v for k,v in j.items() if not k.startswith('_')},'lease':j['_nonce'],'accountProfile':self.gateway.account_profile}
        return {'job':None,'accountProfile':self.gateway.account_profile}

    def authorize_snapshot(self,sid,jid,nonce):
        with self.lock:
            j=self.jobs.get(jid)
            if not j or j['sessionID']!=sid or j['state']!='running' or not secrets.compare_digest(nonce,j.get('_nonce','')) or time.monotonic()>j['_lease']:raise HybridError('Snapshot lease invalid')

    def update(self,jid,body):
        with self.lock:
            j=self.jobs.get(jid)
            if not j or j['state']!='running' or not secrets.compare_digest(str(body.get('lease','')),j.get('_nonce','')):raise HybridError('Build lease expired; stop local process')
            if time.monotonic()>j['_lease'] or time.time()>j['deadline']:j.update(state='failed',error='Build lease expired');raise HybridError('Build lease expired; stop local process')
            j['_lease']=time.monotonic()+self.lease
            if body.get('complete'):
                result=body.get('result',{})
                if not isinstance(result,dict) or len(json.dumps(result).encode())>180000:raise HybridError('Invalid build result')
                attachments=result.get('attachments',[])
                if not isinstance(attachments,list) or len(attachments)>8:raise HybridError('Invalid artifacts')
                for a in attachments:self.gateway.attachment(j['sessionID'],a)
                j.update(state='completed',result=result)
                if attachments:
                    with self.gateway.lock:
                        session=self.gateway.get(j['sessionID'])
                        if session.get('messages') and session['messages'][-1]['role']=='assistant':
                            message=session['messages'][-1]
                            message.setdefault('attachments',[]).extend(self.gateway.attachment_info(self.gateway.attachment(j['sessionID'],a)) for a in attachments)
                            self.gateway.save(session)
            return {'active':True,'accountProfile':self.gateway.account_profile}

    def close(self):
        with self.lock: tokens=list(self.contexts)
        for t in tokens:self.finish(t)
        self.server.shutdown();self.server.server_close();self.directory.cleanup()

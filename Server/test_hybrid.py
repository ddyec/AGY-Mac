import io,json,subprocess,sys,tempfile,threading,time,unittest,uuid
from pathlib import Path
from gateway import Gateway,Failure
from hybrid import HybridError
from test_gateway import FAKE

class HybridTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name).resolve()
        fake=self.root/'agy';fake.write_text(FAKE);fake.chmod(0o700)
        self.g=Gateway(self.root/'db','k'*48,str(fake),[self.root]);self.b=self.g.hybrid
        self.sid=self.g.create({})['id'];s=self.g.get(self.sid);s['approvalMode']='turbo';self.g.save(s)
        self.device=str(uuid.uuid4());self.b.register(self.sid,{'deviceID':self.device,'platform':'macos','architecture':'x86_64','tools':['swift','clang']})
        self.token,self.context=self.b.begin(self.sid,None)
    def tearDown(self):
        self.b.close();self.g.db.close();self.tmp.cleanup()
    def start_build(self,args=None):
        result={}
        def build():
            try:result['value']=self.b.tool(self.token,'build',args or {'command':'swift build','artifacts':['output.zip']})
            except Exception as e:result['error']=e
        t=threading.Thread(target=build);t.start()
        deadline=time.monotonic()+2
        while not self.b.jobs and t.is_alive() and time.monotonic()<deadline:time.sleep(.01)
        return t,result
    def test_device_discovery_scoped_to_conversation_and_expiry(self):
        (self.root/'Package.swift').write_text('// swift')
        self.assertIn('macos',self.b.tool(self.token,'inspect',{})['projectHints'])
        self.assertEqual(len(self.b.inspect(self.sid)['devices']),1)
        other=self.g.create({})['id'];self.assertFalse(self.b.inspect(other)['devices'])
        self.b.devices[(self.sid,self.device)]['seen']-=20
        with self.assertRaises(HybridError):self.b.tool(self.token,'build',{'command':'swift build'})
    def test_job_claim_once_results_and_artifacts_return_to_assistant(self):
        s=self.g.get(self.sid);s['running']=True;s['messages']=[{'id':'assistant','role':'assistant','text':''}];self.g.save(s)
        t,result=self.start_build();dispatch=self.b.poll(self.device);job=dispatch['job'];self.assertIsNotNone(job)
        self.assertIsNone(self.b.poll(self.device)['job'])
        self.b.authorize_snapshot(self.sid,job['id'],dispatch['lease'])
        with self.assertRaises(Failure):self.g.project_snapshot(self.sid)
        stream,_,_=self.g.project_snapshot(self.sid,allow_running=True);stream.close()
        a=self.g.upload(self.sid,'build.log','text/plain',io.BytesIO(b'actual log'),10)
        self.b.update(job['id'],{'lease':dispatch['lease'],'complete':True,'result':{'exitCode':0,'attachments':[a['id']]}})
        t.join(2);self.assertFalse(t.is_alive());self.assertEqual(result['value']['result']['exitCode'],0)
        self.assertEqual(self.g.get(self.sid)['messages'][-1]['attachments'][0]['name'],'build.log')
        with self.assertRaises(HybridError):self.b.update(job['id'],{'lease':dispatch['lease'],'complete':True})
    def test_expired_lease_is_never_requeued_or_replayed(self):
        t,result=self.start_build();d=self.b.poll(self.device);self.b.jobs[d['job']['id']]['_lease']=0
        t.join(2);self.assertEqual(result['value']['state'],'failed');self.assertIsNone(self.b.poll(self.device)['job'])
        with self.assertRaises(HybridError):self.b.update(d['job']['id'],{'lease':d['lease']})
    def test_stop_invalidates_turn_snapshot_and_pending_command(self):
        t,result=self.start_build();d=self.b.poll(self.device);self.b.cancel(self.sid);t.join(2)
        self.assertEqual(result['value']['state'],'cancelled');self.assertFalse(self.context.exists())
        with self.assertRaises(HybridError):self.b.authorize_snapshot(self.sid,d['job']['id'],d['lease'])
        with self.assertRaises(HybridError):self.b.tool(self.token,'inspect',{})
    def test_restriction_approval_contains_actual_command_and_can_deny(self):
        calls=[]
        class Review:
            def wait(self,token,payload):calls.append(payload);return 'deny'
        self.g.review=Review();s=self.g.get(self.sid);s['approvalMode']='review';self.g.save(s)
        self.b.contexts[self.token]=(self.sid,'review-token',self.context)
        with self.assertRaises(HybridError):self.b.tool(self.token,'build',{'command':'swift build'})
        self.assertEqual(calls[0]['toolCall']['args']['command'],'swift build');self.assertFalse(self.b.jobs)
    def test_paths_lease_and_attachment_ownership(self):
        for path in ['../secret','/etc/passwd','~/.ssh','a/../../secret','a\\b']:
            with self.assertRaises(HybridError):self.b.tool(self.token,'build',{'command':'true','artifacts':[path]})
        t,result=self.start_build();d=self.b.poll(self.device)
        with self.assertRaises(HybridError):self.b.update(d['job']['id'],{'lease':'wrong'})
        with self.assertRaises(HybridError):self.b.authorize_snapshot(str(uuid.uuid4()),d['job']['id'],d['lease'])
        other=self.g.create({})['id'];a=self.g.upload(other,'other.log','text/plain',io.BytesIO(b'x'),1)
        with self.assertRaises(Failure):self.b.update(d['job']['id'],{'lease':d['lease'],'complete':True,'result':{'attachments':[a['id']]}})
        self.b.cancel(self.sid);t.join(2)
    def test_native_terminal_helper_round_trip_without_model(self):
        p=subprocess.run([sys.executable,str(Path(__file__).with_name('device_tool.py')),'--context',str(self.context),'inspect'],capture_output=True,text=True,timeout=3)
        self.assertEqual(p.returncode,0);self.assertEqual(json.loads(p.stdout)['devices'][0]['architecture'],'x86_64')
        self.b.finish(self.token)
        p=subprocess.run([sys.executable,str(Path(__file__).with_name('device_tool.py')),'--context',str(self.context),'inspect'],capture_output=True,text=True,timeout=3)
        self.assertNotEqual(p.returncode,0)

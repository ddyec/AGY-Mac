#!/usr/bin/env python3
"""Invoked by AGY's native terminal tool; context expires with its AI turn."""
import argparse,json,socket,sys
from pathlib import Path

def main():
 p=argparse.ArgumentParser();p.add_argument('--context',required=True)
 sub=p.add_subparsers(dest='operation',required=True);sub.add_parser('inspect');b=sub.add_parser('build');b.add_argument('--command',required=True);b.add_argument('--subdirectory',default='.');b.add_argument('--artifact',action='append',default=[])
 a=p.parse_args();c=json.loads(Path(a.context).read_text());args={'command':getattr(a,'command',None),'subdirectory':getattr(a,'subdirectory','.'),'artifacts':getattr(a,'artifact',[])}
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(1230);s.connect(c['socket']);s.sendall(json.dumps({'token':c['token'],'operation':a.operation,'arguments':args}).encode()+b'\n')
  f=s.makefile('rb');result=json.loads(f.readline(256*1024));print(json.dumps(result,ensure_ascii=False))
  return 1 if result.get('error') or result.get('state') in ('failed','cancelled') else 0
if __name__=='__main__':sys.exit(main())

"""Native Pi foreground/background acceptance. Private fixtures; no model calls.

Tests a real Pi RPC child's history loading, then uses deterministic RPC children
for prompt routing, streaming and background completion without provider access.
"""
import fcntl
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

EXTENSION = pathlib.Path(__file__).resolve().parents[1] / 'worker-dashboard' / 'index.ts'
PI = shutil.which('pi')
assert PI

FAKE = r'''
import json, os, pathlib, sys, threading, time
args = sys.argv[1:]
assert args[:2] == ['--mode', 'rpc']
path = pathlib.Path(args[args.index('--session')+1])
header = json.loads(path.read_text().splitlines()[0])
name = header['id']
log = pathlib.Path(os.environ['FAKE_RPC_LOG'])
lock = threading.Lock()
def emit(event):
    with lock:
        print(json.dumps(event), flush=True)
def complete(text):
    time.sleep(1)
    emit({'type':'message_update','assistantMessageEvent':{'type':'text_delta','contentIndex':0,'delta':'BACKGROUND_'+name}})
    time.sleep(1)
    emit({'type':'message_end','message':{'role':'assistant','content':[{'type':'text','text':'DONE_'+name}]}})
    emit({'type':'agent_settled','aborted':False})
for line in sys.stdin:
    req = json.loads(line)
    with log.open('a') as output:
        output.write(json.dumps({'worker':name, **req})+'\n')
    data = {}
    if req['type'] == 'get_state':
        data = {'sessionFile':str(path),'sessionId':name,'model':{'provider':'openai-codex','id':'gpt-6.1-sol'},'thinkingLevel':'high','isStreaming':False}
    elif req['type'] == 'get_messages':
        data = {'messages':[{'role':'assistant','content':[{'type':'text','text':'HISTORY_'+name}]}]}
    elif req['type'] == 'prompt':
        emit({'type':'agent_start'})
        emit({'type':'message_end','message':{'role':'user','content':req['message']}})
        data = {'disposition':'started'}
        threading.Thread(target=complete,args=(req['message'],),daemon=True).start()
    elif req['type'] == 'clear_queue':
        data = {'steering':[],'followUp':[]}
    elif req['type'] == 'abort':
        emit({'type':'agent_settled','aborted':True})
    emit({'type':'response','id':req['id'],'command':req['type'],'success':True,'data':data})
'''


# Local deterministic provider exercises the caller's actual agent loop while
# workers own the screen. No provider credentials, HTTP or real model requests.
ROOT_PROVIDER = r'''
import { writeFileSync } from 'node:fs';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai/compat';
export default function(pi) {
  pi.registerProvider('offline-fixture', {
    baseUrl: 'https://invalid.invalid', apiKey: 'offline-fixture', api: 'offline-fixture-api',
    models: [{ id:'fixture', name:'Offline fixture', reasoning:true, input:['text'],
      contextWindow:128000, maxTokens:1000, cost:{input:0,output:0,cacheRead:0,cacheWrite:0} }],
    streamSimple(model, _context, options) {
      const stream = createAssistantMessageEventStream();
      const message = {role:'assistant',content:[{type:'text',text:''}],api:model.api,provider:model.provider,
        model:model.id,timestamp:Date.now(),stopReason:'pending',
        usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}}};
      void (async () => {
        stream.push({type:'start',partial:message});
        stream.push({type:'text_start',contentIndex:0,partial:message});
        for (let index=0; index<12; index++) {
          if (options?.signal?.aborted) {
            writeFileSync(process.env.ROOT_PROGRESS, 'ABORTED');
            message.stopReason='aborted'; message.errorMessage='Fixture aborted';
            stream.push({type:'error',reason:'aborted',error:message}); stream.end(); return;
          }
          const delta = index===0 ? 'ROOT_STREAM_STARTED' : ' ROOT_BACKGROUND_TICK';
          message.content[0].text+=delta;
          stream.push({type:'text_delta',contentIndex:0,delta,partial:message});
          writeFileSync(process.env.ROOT_PROGRESS, String(index));
          await new Promise(resolve=>setTimeout(resolve,500));
        }
        writeFileSync(process.env.ROOT_PROGRESS, 'DONE');
        message.stopReason='stop';
        stream.push({type:'text_end',contentIndex:0,content:message.content[0].text,partial:message});
        stream.push({type:'done',reason:'stop',message}); stream.end();
      })();
      return stream;
    }
  });
}
'''


def exercise(fake):
    with tempfile.TemporaryDirectory(prefix='pi-multi-tui-') as tmp:
        root = pathlib.Path(tmp)
        run = root / 'runs' / 'run-1'
        (run / 'control').mkdir(parents=True)
        agent = root / 'agent'
        sessions = agent / 'sessions'
        sessions.mkdir(parents=True)
        (root / 'home').mkdir()
        contract = run / 'worker-instructions.md'
        contract.write_text('Private offline acceptance fixture. No tools or model requests are authorized.\n')
        tasks = {}
        for number in (1, 2):
            name = 'worker'+str(number)
            task = run / 'tasks' / name
            cwd = task / 'worktrees'
            cwd.mkdir(parents=True)
            session = sessions / (name+'.jsonl')
            header = {'type':'session','version':3,'id':name,'timestamp':'2026-10-26T00:00:00.000Z','cwd':str(cwd)}
            entry = {'type':'message','id':'00000001','parentId':None,'timestamp':'2026-10-26T00:00:00.000Z',
                     'message':{'role':'user','content':'HISTORY_'+name,'timestamp':1}}
            session.write_text(json.dumps(header)+'\n'+json.dumps(entry)+'\n')
            identity = {'provider':'openai-codex','model':'gpt-6.1-sol','reasoning':'high','session_id':name,'session_file':str(session)}
            (task / 'IDENTITY.json').write_text(json.dumps(identity))
            invocation = {'pid':2147483647,'cwd':str(cwd),'command':['pi','--provider','openai-codex','--model','gpt-6.1-sol',
                          '--thinking','high','--mode','json','--no-extensions','--no-mcp','--no-skills','--no-prompt-templates',
                          '--no-approve','--tools','read,bash,edit,write','--session-id',name,'--append-system-prompt',str(contract),'@NEVER_REPLAY']}
            (task / 'invocation.json').write_text(json.dumps(invocation))
            tasks[name] = {'title':name,'state':'review-required','ended':1,'pid':2147483647,'session_id':name}
        state = {'run':'run-1','provider':'openai-codex','model':'gpt-6.1-sol','thinking':'high','updated':time.time(),'tasks':tasks}
        (run / 'control' / 'state.json').write_text(json.dumps(state))
        env = {k:os.environ[k] for k in ('PATH','LANG') if k in os.environ}
        env.update(HOME=str(root/'home'), TERM='xterm-256color', PI_CODING_AGENT_DIR=str(agent),
                   PI_WORKERS_ROOT=str(root/'runs'), PI_OFFLINE='1', PI_TELEMETRY='0', PI_SKIP_VERSION_CHECK='1')
        log = root / 'rpc.jsonl'
        root_progress = root / 'root-progress'
        root_options = ['--provider','openai-codex','--model','gpt-6.1-sol','--thinking','high']
        if fake:
            provider = root / 'offline-provider.ts'
            provider.write_text(ROOT_PROVIDER)
            env['ROOT_PROGRESS'] = str(root_progress)
            root_options = ['--extension',str(provider),'--provider','offline-fixture','--model','fixture','--thinking','high']
            binary = root / 'bin'
            binary.mkdir()
            program = binary / 'pi'
            program.write_text('#!'+sys.executable+'\n'+FAKE)
            program.chmod(0o700)
            env.update(PATH=str(binary)+':'+env['PATH'], FAKE_RPC_LOG=str(log))
        master, slave = pty.openpty()
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
        child = subprocess.Popen([PI,'--no-extensions','--extension',str(EXTENSION),'--no-mcp','--no-skills',
                                  '--no-prompt-templates','--no-context-files','--no-approve','--no-session','--offline',
                                  *root_options],
                                 cwd=root,env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
        os.close(slave)
        output = bytearray()
        def read(seconds=0.5):
            start = len(output)
            until = time.monotonic()+seconds
            while time.monotonic()<until:
                if select.select([master],[],[],0.05)[0]:
                    try:
                        chunk = os.read(master,65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
                    assert len(output)<4*1024*1024
            return output[start:].decode('utf8','replace')
        def send(text):
            os.write(master,text.encode())
        def wait_for(text, seconds=5):
            start = len(output)
            until = time.monotonic()+seconds
            while time.monotonic()<until:
                read(0.1)
                current = output[start:].decode('utf8','replace')
                if text in current:
                    return current
            raise AssertionError('Missing '+text+'\n'+output[start:].decode('utf8','replace')[-12000:])
        try:
            read(3)
            # Idle handoffs intentionally have no automatic bottom box. The
            # read-only list still exposes their state before any chat loads.
            send('/workers\r'); wait_for('2 review')
            send('\x1b0'); read(0.3)
            if fake:
                send('RUN_OFFLINE_PARENT\r'); wait_for('ROOT_STREAM_STARTED')
            send('ORCHESTRATOR_DRAFT'); read(0.2)
            send('\x1b1'); first = wait_for('HISTORY_worker1')
            assert 'Worker 1 · worker1 · idle' in first, first[-8000:]
            lock1 = sessions / 'worker1.jsonl.worker-chat.lock'
            assert lock1.exists()
            owner = json.loads(lock1.read_text())['pid']
            os.kill(owner, 0) # lease belongs to a live parent runtime
            send('WORKER_ONE_DRAFT'); read(0.2)
            send('\x1b2'); second = wait_for('HISTORY_worker2')
            assert 'Worker 2 · worker2 · idle' in second, second[-8000:]
            send('WORKER_TWO_DRAFT'); read(0.2)
            send('\x1b1'); restored = read(0.4)
            assert 'WORKER_ONE_DRAFT' in restored, restored[-8000:]
            if not fake:
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 10, 24, 0, 0))
                os.kill(child.pid,signal.SIGWINCH); read(0.3)
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
                os.kill(child.pid,signal.SIGWINCH); read(0.3)
            if fake:
                send('\r'); read(0.3)
                send('\x1b2'); read(0.3)
                send('\r'); read(0.3)
            send('\x1b0'); read(0.3)
            send('_PRESERVED'); returned = read(0.3)
            assert 'ORCHESTRATOR_DRAFT_PRESERVED' in returned, returned[-8000:]
            assert lock1.exists(), 'Alt+0 must not unload the worker'
            if fake:
                send('\x15/new\r'); blocked = wait_for('Worker chats are active')
                assert 'New session started' not in blocked, blocked[-8000:]
                read(2.5)
                send('\x1b1'); completed = read(0.5)
                assert 'DONE_worker1' in completed and '· idle' in completed, completed[-8000:]
                send('\x1b2'); completed = read(0.5)
                assert 'DONE_worker2' in completed and '· idle' in completed, completed[-8000:]
                assert root_progress.read_text() == 'DONE', 'calling agent must finish without interruption in background'
                requests = [json.loads(line) for line in log.read_text().splitlines()]
                prompts = [(row['worker'],row['message']) for row in requests if row['type']=='prompt']
                assert prompts == [('worker1','WORKER_ONE_DRAFT'),('worker2','WORKER_TWO_DRAFT')], prompts
                assert not any(row['type']=='abort' for row in requests)
                assert len([row for row in requests if row['type']=='get_state']) == 2, 'switches must reuse processes'
                send('\x1b0'); read(0.2)
            if not fake:
                send('\x15/reload\r'); read(2)
                assert not list(sessions.glob('*.worker-chat.lock')), 'reload must dispose all owned processes'
                send('\x1b1'); wait_for('HISTORY_worker1')
                send('\x1b0'); read(0.2)
            send('\x15/workers close-chats\r'); read(1.5)
            assert not list(sessions.glob('*.worker-chat.lock')), 'close-chats releases session leases'
            assert child.poll() is None
            text = output.decode('utf8','replace')
            assert 'TypeError:' not in text and 'Failed to load extension' not in text and 'ReferenceError:' not in text, text[-12000:]
            print('PASS:', 'actual calling agent loop continues behind concurrent RPC worker chats; prompt routing, streaming and completion' if fake else 'real Pi RPC histories, foreground switching, drafts and detach without unloading')
        finally:
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL)
                child.wait()
            os.close(master)


exercise(False)
exercise(True)

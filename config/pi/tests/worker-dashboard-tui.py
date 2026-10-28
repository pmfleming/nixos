"""Real Pi sidebar acceptance: isolated sessions/runs; offline, no model calls."""
import fcntl, json, os, pathlib, pty, select, signal, struct, subprocess, tempfile, termios, time

extension = pathlib.Path(__file__).resolve().parents[1] / 'worker-dashboard' / 'index.ts'

with tempfile.TemporaryDirectory(prefix='pi-workers-tui-') as tmp:
    root = pathlib.Path(tmp)
    agent = root / 'agent'
    sessions = agent / 'sessions' / '--fixture--'
    sessions.mkdir(parents=True)
    ids = ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', '33333333-3333-4333-8333-333333333333']
    parents = []
    for index, name in enumerate(['SESSION_A', 'SESSION_B', 'EMPTY_SESSION']):
        path = sessions / (name + '.jsonl')
        path.write_text(json.dumps({'type':'session','version':3,'id':ids[index],'cwd':str(root),'timestamp':'2026-10-28T00:00:00Z'}) + '\n' +
                        json.dumps({'type':'session_info','id':'00000001','parentId':None,'name':name,'timestamp':'2026-10-28T00:00:00Z'}) + '\n')
        parents.append(path)
    for index in (0, 1):
        run = root / 'runs' / ('run-' + str(index))
        (run / 'control').mkdir(parents=True)
        (run / 'tasks' / 'worker').mkdir(parents=True)
        (run / 'control/owner.json').write_text(json.dumps({'version':1,'sessionId':ids[index], 'name':'SESSION_' + 'AB'[index], 'cwd':str(root),'created':1}))
        (run / 'control/state.json').write_text(json.dumps({'run':run.name,'provider':'openai-codex','model':'gpt-6.1-sol','thinking':'high','updated':time.time(),
            'tasks':{'worker':{'title':'WORKER_' + 'AB'[index], 'state':'running'}}}))
        (run / 'tasks/worker/PROGRESS.md').write_text('PROGRESS_' + 'AB'[index])
    (root / 'runs/zz-legacy/control').mkdir(parents=True)
    (root / 'runs/zz-legacy/control/state.json').write_text('{')
    (root / 'home').mkdir()
    master, slave = pty.openpty()
    def resize(rows, cols):
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    resize(32, 100)
    env = {k:os.environ[k] for k in ('PATH', 'LANG') if k in os.environ}
    env.update(HOME=str(root/'home'), TERM='xterm-256color', PI_WORKERS_ROOT=str(root/'runs'),
               PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE='1', PI_SKIP_VERSION_CHECK='1', PI_TELEMETRY='0')
    command=['pi','--no-extensions','--extension',str(extension),'--no-mcp','--no-skills','--no-prompt-templates',
             '--no-context-files','--no-approve','--session',str(parents[0]),'--offline','--provider','openai-codex','--model','gpt-6.1-sol','--thinking','high']
    child=subprocess.Popen(command, cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output=bytearray()
    def read_for(seconds):
        start=len(output)
        until=time.monotonic()+seconds
        while time.monotonic()<until:
            if select.select([master],[],[],0.1)[0]:
                try: data=os.read(master,65536)
                except OSError: break
                if not data: break
                output.extend(data)
                assert len(output)<2*1024*1024, 'unbounded output'
        return output[start:].decode('utf8','replace')
    def send(text): os.write(master,text.encode())
    try:
        initial=read_for(3)
        assert 'WORKER_A' not in initial and 'Alt+0 orchestrator' not in initial, initial[-5000:]
        send('ORCHESTRATOR_DRAFT'); read_for(0.3)
        send('\x1bw'); local=read_for(1)
        assert 'Workers · this session' in local and 'WORKER_A' in local, local[-5000:]
        assert 'WORKER_B' not in local and 'zz-legacy' not in local, local[-5000:]
        send('r'); report=read_for(1)
        assert 'PROGRESS_A' in report, report[-5000:]
        (root/'runs/run-0/tasks/worker/PROGRESS.md').write_text('PROGRESS_UPDATED')
        assert 'PROGRESS_UPDATED' in read_for(3)
        send('\x1b0'); read_for(0.3)
        send('_PRESERVED'); returned=read_for(0.3)
        assert 'ORCHESTRATOR_DRAFT_PRESERVED' in returned, returned[-5000:]
        send('\x15/workers-all\r'); all_sessions=read_for(2)
        assert all(name in all_sessions for name in ['All sessions & workers','SESSION_A','SESSION_B','EMPTY_SESSION']), all_sessions[-8000:]
        assert 'WORKER_B' not in all_sessions, 'other session starts collapsed'
        send('\x1b[D'); read_for(0.2)  # collapse A
        send('\x1b[B\r'); expanded=read_for(0.5)  # expand B
        assert 'WORKER_B' in expanded, expanded[-5000:]
        send('\x1b[Br'); foreign_report=read_for(1)
        assert 'PROGRESS_B' in foreign_report, foreign_report[-5000:]
        send('\x1b0'); read_for(0.3)
        # Global numbered shortcuts always refer to the calling session.
        send('\x1b1'); live=read_for(1)
        assert 'JSON process cannot be attached' in live, live[-5000:]
        send('\x1b0'); read_for(0.3)
        send('/workers\r'); read_for(0.5)
        resize(6, 12); os.kill(child.pid,signal.SIGWINCH); read_for(0.5)
        resize(32,100); os.kill(child.pid,signal.SIGWINCH); read_for(0.5)
        send('\x1b0'); read_for(0.3)
        send('/new\r'); read_for(1)
        send('/workers\r'); empty=read_for(1)
        assert 'No workers associated with this session' in empty, empty[-5000:]
        assert 'WORKER_A' not in empty and 'WORKER_B' not in empty, empty[-5000:]
        send('\x1b0'); read_for(0.3)
        send('/reload\r'); read_for(2)
        send('/workers\r'); empty=read_for(1)
        assert 'No workers associated with this session' in empty, empty[-5000:]
        assert child.poll() is None
        text=output.decode('utf8','replace')
        assert all(error not in text for error in ['Failed to load extension','TypeError:','ReferenceError:']), text[-8000:]
        print('PASS: two native Pi sidebars, session ownership, expandable worker submenus, reports, no bottom widget, draft preservation, resize, new-session isolation and reload')
    finally:
        if child.poll() is None: os.killpg(child.pid,signal.SIGTERM)
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL); child.wait()
        os.close(master)

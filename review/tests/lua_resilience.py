"""Run production bridge callbacks with native/IO fault injection."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'test_deps'),str(ROOT.parent/'radar_review_20261017/test_deps'),str(ROOT.parent/'radar_data_release_20261016/analysis_deps')]
from lupa import LuaRuntime
import tree_sitter,tree_sitter_lua
source=ROOT/'source/scripts/main.lua';b=source.read_bytes()
parser=tree_sitter.Parser(tree_sitter.Language(tree_sitter_lua.language()))
def walk(node):
    yield node
    for child in node.children:yield from walk(child)
names=['write_atomic_text','wcn_write_state','wcn_accept_counts','wcn_poll_once',
       'wcx_write_minigame_state','request_runtime161_burst','wcx_poll_once',
       'queue_area_quest_complete','dqx_poll_once']
functions=[]
for name in names:
    found=[n for n in walk(parser.parse(b).root_node) if n.type=='function_declaration' and b[n.start_byte:n.end_byte].decode().startswith('local function '+name+'(')]
    assert len(found)==1,name
    functions.append(b[found[0].start_byte:found[0].end_byte].decode())
prefix=r'''
local sink={}
local WCN_STATE_PATH,WCX_MINIGAME_STATE_PATH,RUNTIME161_BURST_REQUEST_PATH,AREA_QUEST_QUEUE_PATH='chest.json','mini.json','burst','area'
local wcn_installed,wcx_installed,dqx_installed=true,true,true
local wcn_last_seq,wcx_last_seq,dqx_last_seq=-1,-1,-1
local wcn_last_event,wcn_last_count_sig,wcx_last_count_sig='none',nil,nil
local area_catalog,area_emitted={[147]=true},{}
local function log(s) sink.logs[#sink.logs+1]=s end
local function wcn_hex(n) return tostring(n) end
local function wcx_mission_name(n) return tostring(n) end
local function consume_save_boundary_reset() end
local function ExecuteWithDelay(ms,fn)
  sink.scheduled[#sink.scheduled+1]={ms=ms,fn=fn};sink.schedules=sink.schedules+1
end
local function fails(path,mode)
  return sink.mode==mode and (sink.fail_path==nil or sink.fail_path==path)
end
local io={open=function(path,mode)
  if fails(path,'open-fail') then return nil end
  local f={body=mode=='a' and (sink.files[path] or '') or ''}
  function f:write(...)
    sink.writes=sink.writes+1
    if fails(path,'write-fail') then return nil,'controlled write error' end
    self.body=self.body..table.concat({...});return self
  end
  function f:close()
    if fails(path,'close-fail') then return nil,'controlled close error' end
    sink.files[path]=self.body;return true
  end
  return f
end}
local os={time=function() return 1001 end,
  rename=function(a,b)
    if sink.mode=='locked-target' or sink.mode=='rename-fail' then return nil,'controlled rename error' end
    if sink.files[a]==nil then return nil end
    sink.files[b]=sink.files[a];sink.files[a]=nil;return true
  end,
  remove=function(path)
    if sink.mode=='locked-target' then return nil end
    sink.files[path]=nil;return true
  end}
local wcn_poll_fn=function()
  if sink.poll_error then error('controlled native exception') end
  return 7,0,1,123,1,1,2,1503,99
end
local wcx_poll_fn=function()
  if sink.poll_error then error('controlled native exception') end
  return 8,0,2,1,4,84,99
end
local dqx_poll_fn=function()
  if sink.poll_error then error('controlled native exception') end
  return 9,147,1,1,123
end
local function reset()
  sink.files={['chest.json']='old chest state',['mini.json']='old minigame state'}
  sink.logs={};sink.scheduled={};sink.schedules=0;sink.writes=0;sink.mode='ok';sink.fail_path=nil;sink.poll_error=false
  wcn_installed,wcx_installed,dqx_installed=true,true,true
  wcn_last_seq,wcx_last_seq,dqx_last_seq=-1,-1,-1
  wcn_last_event,wcn_last_count_sig,wcx_last_count_sig='none',nil,nil
  area_emitted={}
end
'''
suffix=r'''
return {sink=sink,reset=reset,accept=wcn_accept_counts,write=write_atomic_text,burst=request_runtime161_burst,
  wcn=wcn_poll_once,wcx=wcx_poll_once,dqx=dqx_poll_once,
  sequence=function(tag) if tag=='wcx' then return wcx_last_seq else return dqx_last_seq end end,
  signature=function() return wcn_last_count_sig end,
  run_next=function() local task=table.remove(sink.scheduled,1);task.fn() end,
  disable=function() wcn_installed=false;wcx_installed=false;dqx_installed=false end}
'''
api=LuaRuntime(unpack_returned_tuples=True).execute(prefix+'\n'+'\n'.join(functions)+'\n'+suffix)
checks=[]
def check(name,ok):
    checks.append({'name':name,'passed':bool(ok)});assert ok,name
for mode in ['open-fail','write-fail','close-fail','locked-target']:
    api.reset();api.sink.mode=mode
    check(mode+' is reported without acknowledging chest count',not api.accept(1,2,1503,99,'test') and api.signature() is None)
    check(mode+' does not publish a truncated destination',api.sink.files['chest.json']=='old chest state')
    api.sink.mode='ok'
    check(mode+' retries the identical native count successfully',api.accept(1,2,1503,99,'retry') and json.loads(api.sink.files['chest.json'])['opened']==2)
api.reset();api.accept(1,2,1503,99,'first');writes=api.sink.writes
api.accept(1,2,1503,99,'unchanged')
check('successful unchanged chest counts avoid repeated writes',api.sink.writes==writes)
for tag in ['wcn','wcx','dqx']:
    api.reset();api.sink.poll_error=True;api[tag]()
    check(tag+' native exception leaves exactly one retry scheduled',api.sink.schedules==1 and len(api.sink.scheduled)==1)
    api.sink.poll_error=False;api.run_next()
    check(tag+' recovers through its scheduled callback',api.sink.schedules==2 and len(api.sink.scheduled)==1 and api.sink.writes>0)
api.reset();api.sink.files['burst']='phase=transition;source=watcher\n'
check('Lua completion request preserves the pending transition',api.burst('test') and api.sink.files['burst'].startswith('phase=transition;') and '\nphase=completion;' in api.sink.files['burst'])
for mode in ['open-fail','write-fail','close-fail']:
    api.reset();api.sink.mode=mode;api.sink.fail_path='burst'
    check('burst '+mode+' is reported for retry',not api.burst('test'))
api.reset();api.sink.mode='write-fail';api.sink.fail_path='mini.json.tmp';api.wcx()
check('failed minigame state does not consume native sequence',api.sequence('wcx')==-1 and len(api.sink.scheduled)==1)
api.sink.mode='ok';api.run_next()
check('same minigame sequence retries state and burst publication',api.sequence('wcx')==8 and json.loads(api.sink.files['mini.json'])['opened']==4 and 'phase=completion;' in api.sink.files['burst'])
api.reset();api.sink.mode='write-fail';api.sink.fail_path='burst';api.wcx()
check('failed minigame burst publication keeps sequence retryable',api.sequence('wcx')==-1)
api.sink.mode='ok';api.run_next()
check('minigame burst failure recovers on the next scheduled poll',api.sequence('wcx')==8 and 'phase=completion;' in api.sink.files['burst'])
api.reset();api.sink.mode='write-fail';api.sink.fail_path='area';api.dqx()
check('area queue write failure does not consume native sequence',api.sequence('dqx')==-1 and len(api.sink.scheduled)==1)
api.sink.mode='ok';api.run_next()
check('same area event retries after a queue failure',api.sequence('dqx')==9 and api.sink.files['area'].count('AREA_QUEST_COMPLETE')==1)
api.run_next()
check('completed area sequence does not emit duplicates',api.sink.files['area'].count('AREA_QUEST_COMPLETE')==1)
api.reset();api.disable()
for tag in ['wcn','wcx','dqx']:api[tag]()
check('disabled bridges do not schedule polling work',api.sink.schedules==0)
result={'passed':True,'checks':checks,'source_sha256':hashlib.sha256(b).hexdigest(),
        'test_kind':'production Lua callbacks with native and filesystem fault injection','game_runtime_executed':False}
(ROOT/'audit/lua_resilience.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS:',len(checks),'Lua resilience checks')

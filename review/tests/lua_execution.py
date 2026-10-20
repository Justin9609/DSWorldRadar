"""Execute the actual Lua queue producers with controlled IO failure injection."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'test_deps'),str(ROOT.parent/'radar_review_20261017/test_deps'),str(ROOT.parent/'radar_data_release_20261016/analysis_deps')]
from lupa import LuaRuntime
import tree_sitter,tree_sitter_lua
source=ROOT/'source/scripts/main.lua';b=source.read_bytes()
parser=tree_sitter.Parser(tree_sitter.Language(tree_sitter_lua.language()))
def walk(n):
    yield n
    for c in n.children:yield from walk(c)
funcs=[]
for name in ['queue','queue_candidate','queue_area_quest_complete']:
    found=[n for n in walk(parser.parse(b).root_node) if n.type=='function_declaration' and b[n.start_byte:n.end_byte].decode().startswith('local function '+name+'(')]
    assert len(found)==1,(name,len(found));funcs.append(b[found[0].start_byte:found[0].end_byte].decode())
lua=LuaRuntime(unpack_returned_tuples=True)
harness=r'''
local emitted,area_emitted={},{}
local area_catalog={[147]=true}
local QUEUE_PATH,AREA_QUEST_QUEUE_PATH='chest','area'
local sink={mode='ok',records={},logs={}}
local function log(s) sink.logs[#sink.logs+1]=s end
local io={open=function(path,mode)
  if sink.mode=='open-fail' then return nil end
  local f={}
  function f:write(...)
    if sink.mode=='write-fail' then return nil,'controlled-write-failure' end
    local args={...};sink.records[#sink.records+1]=table.concat(args);return self
  end
  function f:close() if sink.mode=='close-fail' then return nil,'controlled-close-failure' end;return true end
  return f
end}
local os={time=function() return 1001 end}
'''
api=lua.execute(harness+'\n'+'\n'.join(funcs)+'\nreturn {queue=queue,candidate=queue_candidate,area=queue_area_quest_complete,sink=sink,emitted=emitted,area_emitted=area_emitted}')
checks=[]
def check(name,ok):
    checks.append({'name':name,'passed':bool(ok)});assert ok,name
for method,key in [('queue','11230106'),('candidate','candidate:11230107')]:
    sid=11230106 if method=='queue' else 11230107
    for failure in ['open-fail','write-fail','close-fail']:
        api.sink.mode=failure
        api[method](sid,'opened','TreasureBox03_C',1,2,3,4)
        check(f'{method} {failure} does not poison event dedup',api.emitted[key] is None)
    api.sink.mode='ok';api[method](sid,'opened','TreasureBox03_C',1,2,3,4)
    check(f'{method} records success only after close',api.emitted[key] is True)
    last=api.sink.records[len(api.sink.records)]
    check(f'{method} event carries current-process timestamp',len(last.strip().split('|'))==8 and last.strip().endswith('|1001'))
    before=len(api.sink.records);api[method](sid,'opened','TreasureBox03_C',1,2,3,4)
    check(f'{method} repeated successful callback is deduplicated',len(api.sink.records)==before)
for failure in ['open-fail','write-fail','close-fail']:
    api.sink.mode=failure;api.area(147,'native-writer')
    check('area '+failure+' remains retryable',api.area_emitted['147'] is None)
api.sink.mode='ok';check('valid area completion is emitted',api.area(147,'native-writer') is True)
check('unknown area quest cannot enter queue',api.area(999999,'native-writer') is False)
result={'passed':True,'checks':checks,'source_sha256':hashlib.sha256(b).hexdigest(),'runtime':'Lupa '+str(lua.eval('_VERSION')),'game_runtime_executed':False}
(ROOT/'audit/lua_execution.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS:',len(checks),'actual Lua producer checks')

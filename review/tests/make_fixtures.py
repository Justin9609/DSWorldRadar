"""Generate disposable synthetic SQLCipher-compatible save fixtures, never user saves."""
from pathlib import Path
import argparse,csv,hashlib,json,os,re,shutil,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'test_deps'))
import apsw
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
arg=argparse.ArgumentParser(description=__doc__)
arg.add_argument('--mod-root',type=Path,default=ROOT.parent/'radar_sync_fix_20261016/stage/DSWorldRadar_v1.0.3_Without_UE4SS/DS/Binaries/Win64/ue4ss/Mods/DSWorldRadar')
BASE=arg.parse_args().mod_root
fixture=Path(tempfile.mkdtemp(prefix='dswr-review-fixture-'))
game=fixture/'game with spaces';tool=game/'DS/Binaries/Win64/ue4ss/Mods/DSWorldRadar/dlls/sync'
tool.mkdir(parents=True)
(game/'DS/Content/Paks').mkdir(parents=True)
(game/'DS/Binaries/Win64/DSClient-Win64-Shipping.exe').write_bytes(b'synthetic-only')
for name in ['mnm_nodes.csv','mnm_ids.csv','marmot_locations.csv']:
    shutil.copyfile(BASE/'dlls'/name,tool.parent/name)
shutil.copytree(BASE/'dlls/lang',tool.parent/'lang')
saves=game/'DS/Saved/SaveGames/account';saves.mkdir(parents=True)
nodes=list(csv.DictReader((tool.parent/'mnm_nodes.csv').open(encoding='utf-8-sig')))
chests=[int(r['id'][4:]) for r in nodes if r['id'].startswith('DSC_')]
areas=[r['id'] for r in csv.DictReader((tool.parent/'mnm_ids.csv').open(encoding='utf-8-sig')) if r['kind']=='area_quests']
# Read the shipping helper's game-format password privately; never print or persist it separately.
source=(ROOT/'source/dlls/sync/MnMChestSaveSync.cs').read_text()
password=re.search(r'SqlCipherPass = Encoding.ASCII.GetBytes\("([^"]+)"\)',source)[1].encode()
def create(name,opened,malformed=False):
    plain=fixture/(name+'.plain.db')
    con=apsw.Connection(str(plain));con.execute('PRAGMA page_size=4096');con.reserve_bytes(reserve=80)
    con.execute('CREATE TABLE tb_treasure_box(CATEGORY INTEGER,OPENED_BIT_FIELD INTEGER)')
    groups={}
    for n in opened:groups[n//64]=groups.get(n//64,0)|(1<<(n%64))
    for category,field in groups.items():
        if field>=(1<<63):field-=1<<64
        con.execute('INSERT INTO tb_treasure_box VALUES(?,?)',(category,field))
    if malformed:con.execute('CREATE TABLE tb_dynamic_quest_complete(QUEST_ID INTEGER)')
    else:
        con.execute('CREATE TABLE tb_dynamic_quest_complete(QUEST_ID INTEGER,COMPLETE_CNT INTEGER)')
        for qid,cnt in [(int(areas[0]),1),(int(areas[1]),0),(int(areas[2]),-1)]:
            con.execute('INSERT INTO tb_dynamic_quest_complete VALUES(?,?)',(qid,cnt))
    con.execute('VACUUM');con.close()
    data=plain.read_bytes();assert data[20]==80 and len(data)%4096==0
    salt=hashlib.sha256(name.encode()).digest()[:16]
    key=hashlib.pbkdf2_hmac('sha512',password,salt,256000,32)
    encrypted=bytearray()
    for pn,st in enumerate(range(0,len(data),4096)):
        iv=hashlib.sha256((name+str(pn)).encode()).digest()[:16]
        ct=Cipher(algorithms.AES(key),modes.CBC(iv)).encryptor().update(data[st+(16 if pn==0 else 0):st+4096-80])
        encrypted.extend((salt if pn==0 else b'')+ct+iv+b'\0'*64)
    assert len(encrypted)==len(data)
    dest=saves/(name+'.db');dest.write_bytes(encrypted);plain.unlink()
    return str(dest)
paths={
    'A':create('account_SlotA',chests),
    'B':create('account_SlotB',[x for x in chests if x!=11230106]),
    'empty':create('account_SlotEmpty',[]),
    'malformed':create('account_SlotBadSchema',chests,True),
}
# Preserve an independent valid backup beside a deliberately damaged primary.
bad=saves/'account_SlotCorrupt.db';bad.write_bytes(b'invalid-primary')
shutil.copyfile(paths['A'],bad.with_suffix('.bak'));paths['corrupt']=str(bad)
paths.update(root=str(fixture),game=str(game),tool=str(tool),area_positive=areas[0],area_zero=areas[1],area_negative=areas[2])
(ROOT/'tests/fixture_paths.json').write_text(json.dumps(paths,indent=2)+'\n')
print('Synthetic encrypted fixtures prepared: A=1503, B=1502, empty, malformed schema, corrupt primary')

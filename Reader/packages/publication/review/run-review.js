import fs from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {zip,epub} from '../test/fixtures.js';
const here=path.dirname(fileURLToPath(import.meta.url));const root=path.join(here,'work');await fs.mkdir(root,{recursive:true});
function run(source,managed){const p=spawnSync(path.join(here,'build/probe'),[source,managed],{encoding:'utf8',env:{...process.env,DYLD_LIBRARY_PATH:path.join(here,'build')}});return {code:p.status,output:p.stdout.trim(),stderr:p.stderr.trim()};}
const results=[];
async function test(name,entries){const source=path.join(root,name+'.epub');await fs.writeFile(source,zip(entries));const managed=path.join(root,name);const result=run(source,managed);results.push({name,...result});return {source,managed,result};}
await test('valid',epub());
await test('parent-after-child',epub({extra:[{name:'EPUB',data:'conflicting file'}]}));
await test('parent-before-child',[{name:'EPUB',data:'conflicting file'},...epub()]);
await test('size-lie',epub({extra:[{name:'EPUB/lie',method:8,data:'abc'.repeat(1000),size:1}]}));
await test('bad-crc',epub({extra:[{name:'EPUB/bad',data:'bad',crc:1}]}));
await test('local-name-mismatch',epub({extra:[{name:'EPUB/fine',localName:'EPUB/evil',data:'bad'}]}));
await test('windows-superscript-device',epub({extra:[{name:'EPUB/COM¹.txt',data:'device'}]}));
await test('multiple-explicit-covers',epub({opfTransform:x=>x.replace('id="chapter"','id="chapter" properties="cover-image"')}));
await test('wrong-namespace-no-package',epub({opfTransform:x=>x.replaceAll('package','random').replace('http://www.idpf.org/2007/opf','https://example.invalid/')}));
await test('rights-marker',epub({extra:[{name:'META-INF/rights.xml',data:'<rights/>'}]}));
const t=await test('tamper-managed-original',epub());
const id=t.result.output.split(' ')[1];if(id){await fs.writeFile(path.join(t.managed,id,'original.epub'),'broken managed original');results.push({name:'duplicate-after-original-corruption',...run(t.source,t.managed)});}
console.log(JSON.stringify(results,null,2));await fs.writeFile(path.join(here,'results.json'),JSON.stringify(results,null,2));

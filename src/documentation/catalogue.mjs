import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root=path.resolve(import.meta.dirname,'../..');
const entry=path.join(root,'workspace');
const start='<!-- DOCUMENT-CATALOGUE:START -->';
const end='<!-- DOCUMENT-CATALOGUE:END -->';
const fields=['id','title','summary','updated'];
const auxiliaryNames=['README.md'];
const timestampPattern=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+08:00$/;
const stamp=()=>new Date(Date.now()+8*3600000).toISOString().slice(0,19)+'+08:00';
function read(file){
 const content=fs.readFileSync(file,'utf8').replaceAll('\r\n','\n');
 const header=/^---\n([\s\S]*?)\n---\n/.exec(content);
 if(!header)throw Error(`${file}: missing YAML front matter`);
 const meta={};
 for(const line of header[1].split('\n')){
  if(!line.trim()||line.trimStart().startsWith('#'))continue;
  const match=/^([a-z]+):\s*(.+)$/.exec(line);
  if(!match||!fields.includes(match[1]))throw Error(`${file}: only id/title/summary/updated scalar fields are allowed`);
  if(Object.hasOwn(meta,match[1]))throw Error(`${file}: duplicate ${match[1]}`);
  let value=match[2].trim();
  if(value.startsWith('"'))value=JSON.parse(value);
  else if(value.startsWith("'")&&value.endsWith("'"))value=value.slice(1,-1).replaceAll("''","'");
  if(typeof value!=='string'||!value.trim())throw Error(`${file}: ${match[1]} must be a nonempty string`);
  meta[match[1]]=value;
 }
 for(const field of fields)if(!Object.hasOwn(meta,field))throw Error(`${file}: missing ${field}`);
 if(!/^[a-z][a-z0-9-]*$/.test(meta.id))throw Error(`${file}: invalid stable id`);
 if(!timestampPattern.test(meta.updated)||!Number.isFinite(Date.parse(meta.updated)))throw Error(`${file}: updated must be YYYY-MM-DDTHH:mm:ss+08:00`);
 const body=content.slice(header[0].length);
 if(!body.trimStart().startsWith('# '+meta.title+'\n'))throw Error(`${file}: first heading must match title`);
 return {file,content,meta,body};
}
function touch(file,time){
 const doc=read(file);
 const header=doc.content.slice(0,doc.content.length-doc.body.length).replace(/^updated:.*$/m,'updated: '+JSON.stringify(time));
 fs.writeFileSync(file,header+doc.body);
}
function checkLinks(doc){
 for(const match of doc.body.matchAll(/(?<!!)\[[^\]]*\]\(([^)]+)\)/g)){
  const target=match[1];
  if(target.startsWith('#')||/^[a-z]+:/i.test(target))continue;
  const relative=decodeURIComponent(target.split('#')[0]);
  if(relative&&!fs.existsSync(path.resolve(path.dirname(doc.file),relative)))throw Error(`${doc.file}: broken link ${target}`);
 }
}
export function catalogue(args=process.argv.slice(2)){
 const check=args.includes('--check');
 const touchAll=args.includes('--touch-all');
 const touched=[];
 for(let i=0;i<args.length;i++){
  if(args[i]==='--touch'){
   const name=args[++i];
   if(!name||path.basename(name)!==name||!(name==='AGENTS.md'||/^\d{2}-.+\.md$/.test(name)))throw Error('--touch needs an entry document filename');
   touched.push(name);
  }else if(!['--check','--touch-all'].includes(args[i]))throw Error('Unknown argument: '+args[i]);
 }
 if(check&&(touchAll||touched.length))throw Error('--check cannot modify files');
 const names=fs.readdirSync(entry).filter(name=>/^\d{2}-.+\.md$/.test(name)).sort();
 if(!names.length)throw Error('No numbered entry documents found');
 const agentsFile=path.join(entry,'AGENTS.md');
 const auxiliary=auxiliaryNames.map(name=>path.join(root,name)).filter(file=>fs.existsSync(file));
 if(touchAll){const time=stamp();for(const file of [agentsFile,...names.map(name=>path.join(entry,name)),...auxiliary])touch(file,time);}
 else for(const name of touched)touch(path.join(entry,name),stamp());
 const docs=names.map(name=>read(path.join(entry,name)));
 const agents=read(agentsFile);
 const ids=new Set([agents.meta.id]);const numbers=new Set();
 for(const doc of docs){
  if(ids.has(doc.meta.id))throw Error('Duplicate id: '+doc.meta.id);ids.add(doc.meta.id);
  const name=path.basename(doc.file);const number=name.slice(0,2);
  if(numbers.has(number))throw Error('Duplicate number: '+number);numbers.add(number);
  if(name.slice(3,-3)!==doc.meta.title)throw Error(name+': filename must match title');
  checkLinks(doc);
 }
 for(const file of auxiliary){
  const doc=read(file);
  if(ids.has(doc.meta.id))throw Error('Duplicate id: '+doc.meta.id);
  ids.add(doc.meta.id);checkLinks(doc);
 }
 const generated=[start,'',...docs.flatMap(doc=>[
  `### ${path.basename(doc.file).slice(0,2)} · ${doc.meta.title}`,'',
  `- 标识：\`${doc.meta.id}\``,
  `- 简介：${doc.meta.summary}`,
  `- 更新：\`${doc.meta.updated}\``,
  `- 正文：[${path.basename(doc.file)}](${path.basename(doc.file)})`,''
 ]),end].join('\n');
 const first=agents.content.indexOf(start);const last=agents.content.indexOf(end);
 if(first<0||last<first||agents.content.indexOf(start,first+start.length)>=0||agents.content.indexOf(end,last+end.length)>=0)throw Error('AGENTS.md needs exactly one catalogue marker pair');
 let expected=agents.content.slice(0,first)+generated+agents.content.slice(last+end.length);
 const changed=expected!==agents.content;
 if(check&&changed)throw Error('AGENTS.md catalogue differs from document metadata; refresh it');
 if(!check&&changed){
  expected=expected.replace(/^updated:.*$/m,'updated: '+JSON.stringify(stamp()));
  fs.writeFileSync(agentsFile,expected);
 }
 checkLinks(read(agentsFile));
 return {mode:check?'check':'refresh',documents:docs.length,navigationDocuments:auxiliary.length,fields,updatedFormat:'YYYY-MM-DDTHH:mm:ss+08:00',catalogueChanged:!check&&changed};
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 try{console.log(JSON.stringify(catalogue(),null,2));}
 catch(error){console.error(error.message);process.exitCode=1;}
}

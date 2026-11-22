import fs from 'node:fs';
import path from 'node:path';
export const root=path.resolve(import.meta.dirname,'../..');
export const configuration=JSON.parse(fs.readFileSync(path.join(root,'config/runtime.json'),'utf8'));
if(configuration.schemaVersion!==1)throw new Error('Unsupported runtime configuration');
export const paths=Object.fromEntries(Object.entries(configuration.paths).map(([key,relative])=>{
  const target=path.resolve(root,relative);
  if(!target.startsWith(root+path.sep))throw new Error(`Path outside runtime directory: ${key}`);
  return [key,target];
}));

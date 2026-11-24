import {createCipheriv, createDecipheriv} from 'node:crypto';
import {readFileSync} from 'node:fs';

const input = readFileSync(0);
const key = input.subarray(0, 16);
const content = input.subarray(16);
const operation = process.argv[2];
if (operation !== 'encrypt' && operation !== 'decrypt') throw Error('Unknown operation');
const transform = operation === 'encrypt' ? createCipheriv : createDecipheriv;
const cipher = transform('aes-128-ecb', key, null);
process.stdout.write(Buffer.concat([cipher.update(content), cipher.final()]));

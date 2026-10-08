'use strict';
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const root = path.resolve(__dirname, '../ios/Daylight/Assets.xcassets');
const dir = path.join(root, 'AppIcon.appiconset');
fs.mkdirSync(dir, { recursive:true });
const size = 1024, rows = Buffer.alloc((size * 3 + 1) * size);
const coverage = distance => Math.max(0, Math.min(1, 1 - distance));
for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) {
  const offset = y * (size * 3 + 1) + 1 + x * 3, blend = (x + y) / (2 * size);
  const background = [32 + 28 * blend, 112 + 49 * blend, 230 + 18 * blend];
  const sun = coverage(Math.hypot(x - 512, y - 466) - 124);
  const horizon = coverage(Math.hypot(Math.max(Math.abs(x - 512) - 244, 0), y - 676) - 18);
  const rayTop = coverage(Math.hypot(x - 512, Math.max(Math.abs(y - 244) - 28, 0)) - 13);
  const rayLeft = coverage(Math.hypot(Math.max(Math.abs(x - 272) - 24, 0), y - 466) - 13);
  const rayRight = coverage(Math.hypot(Math.max(Math.abs(x - 752) - 24, 0), y - 466) - 13);
  const alpha = Math.max(sun, horizon * 0.90, rayTop * 0.85, rayLeft * 0.85, rayRight * 0.85);
  for (let c = 0; c < 3; c++) rows[offset + c] = Math.round(background[c] * (1 - alpha) + 255 * alpha);
}
const table = Array.from({length:256}, (_, n) => { for(let k=0;k<8;k++) n=(n&1)?0xedb88320^(n>>>1):n>>>1; return n>>>0; });
const crc = bytes => { let n=0xffffffff; for(const byte of bytes) n=table[(n^byte)&255]^(n>>>8); return (n^0xffffffff)>>>0; };
function chunk(type, data) { const length=Buffer.alloc(4), checksum=Buffer.alloc(4), name=Buffer.from(type); length.writeUInt32BE(data.length); checksum.writeUInt32BE(crc(Buffer.concat([name,data]))); return Buffer.concat([length,name,data,checksum]); }
const header=Buffer.alloc(13); header.writeUInt32BE(size,0);header.writeUInt32BE(size,4);header[8]=8;header[9]=2;
fs.writeFileSync(path.join(dir,'AppIcon.png'), Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',zlib.deflateSync(rows)),chunk('IEND',Buffer.alloc(0))]));
fs.writeFileSync(path.join(root,'Contents.json'), JSON.stringify({info:{author:'xcode',version:1}},null,2));
fs.writeFileSync(path.join(dir,'Contents.json'), JSON.stringify({images:[{filename:'AppIcon.png',idiom:'universal',platform:'ios',size:'1024x1024'}],info:{author:'xcode',version:1}},null,2));
console.log('已生成 1024 × 1024 不透明 App 图标。');

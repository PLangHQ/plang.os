// vhd.js <raw.img> <out.vhd>: a raw disk image as a dynamic VHD (Microsoft's Virtual Hard Disk format, v1.0) —
// what `wsl --mount --vhd` attaches. Only blocks with data are written (2 MB each), so a 32 GB disk with an
// empty filesystem is a few MB. Spec: "Virtual Hard Disk Image Format Specification" (footer, dynamic header,
// block allocation table, blocks of a sector bitmap + data). Deterministic for a given raw image and time.
const fs = require('fs');
const crypto = require('crypto');
const [raw, out] = process.argv.slice(2);
const size = fs.statSync(raw).size;
const BLOCK = 2 * 1024 * 1024, SECTOR = 512;
if (size % BLOCK) throw new Error('raw size must be a multiple of 2 MB');
const blocks = size / BLOCK;

const be32 = (b, o, v) => b.writeUInt32BE(v >>> 0, o);
const be64 = (b, o, v) => b.writeBigUInt64BE(BigInt(v), o);
const checksum = b => { let s = 0; for (const x of b) s += x; return (~s) >>> 0; };

// CHS geometry, as the spec's algorithm computes it
function geometry(bytes) {
  let total = Math.min(bytes / SECTOR, 65535 * 16 * 255);
  let spt, heads, cth;
  if (total >= 65535 * 16 * 63) { spt = 255; heads = 16; cth = Math.floor(total / spt); }
  else {
    spt = 17; cth = Math.floor(total / spt); heads = Math.floor((cth + 1023) / 1024); if (heads < 4) heads = 4;
    if (cth >= heads * 1024 || heads > 16) { spt = 31; heads = 16; cth = Math.floor(total / spt); }
    if (cth >= heads * 1024) { spt = 63; heads = 16; cth = Math.floor(total / spt); }
  }
  return { cyl: Math.floor(cth / heads), heads, spt };
}

const epoch = process.env.SOURCE_DATE_EPOCH ? +process.env.SOURCE_DATE_EPOCH : Math.floor(Date.now() / 1000);
const stamp = epoch - 946684800;   // seconds since 2000-01-01 UTC

function footer() {
  const f = Buffer.alloc(512);
  f.write('conectix', 0, 'ascii');
  be32(f, 8, 2);                 // features: reserved bit
  be32(f, 12, 0x00010000);       // format version
  be64(f, 16, 512);              // the dynamic header's offset
  be32(f, 24, stamp);
  f.write('plng', 28, 'ascii');  // creator application
  be32(f, 32, 0x00010000);
  f.write('Wi2k', 36, 'ascii');  // creator host OS
  be64(f, 40, size); be64(f, 48, size);
  const g = geometry(size);
  f.writeUInt16BE(g.cyl, 56); f.writeUInt8(g.heads, 58); f.writeUInt8(g.spt, 59);
  be32(f, 60, 3);                // disk type: dynamic
  crypto.createHash('sha256').update(raw + epoch).digest().copy(f, 68, 0, 16);   // unique id
  be32(f, 64, checksum(f));
  return f;
}

const tableBytes = Math.ceil(blocks * 4 / SECTOR) * SECTOR;
function header() {
  const h = Buffer.alloc(1024);
  h.write('cxsparse', 0, 'ascii');
  be64(h, 8, 0xFFFFFFFFFFFFFFFFn);
  be64(h, 16, 1536);             // the block allocation table's offset
  be32(h, 24, 0x00010000);
  be32(h, 28, blocks);
  be32(h, 32, BLOCK);
  be32(h, 36, checksum(h));
  return h;
}

const fd = fs.openSync(raw, 'r'), o = fs.openSync(out, 'w');
const bat = Buffer.alloc(tableBytes, 0xFF);
const bitmap = Buffer.alloc(SECTOR, 0xFF);   // every sector of a written block is present
const data = Buffer.alloc(BLOCK), zero = Buffer.alloc(BLOCK);
let at = 1536 + tableBytes;                  // first block, sector-aligned
const foot = footer();
fs.writeSync(o, foot, 0, 512, 0);
fs.writeSync(o, header(), 0, 1024, 512);
let written = 0;
for (let i = 0; i < blocks; i++) {
  fs.readSync(fd, data, 0, BLOCK, i * BLOCK);
  if (data.equals(zero)) continue;   // a block never written reads as zeros
  be32(bat, i * 4, at / SECTOR);
  fs.writeSync(o, bitmap, 0, SECTOR, at);
  fs.writeSync(o, data, 0, BLOCK, at + SECTOR);
  at += SECTOR + BLOCK;
  written++;
}
fs.writeSync(o, bat, 0, tableBytes, 1536);
fs.writeSync(o, foot, 0, 512, at);
fs.closeSync(fd); fs.closeSync(o);
console.log(`${out}: ${size / 1024 ** 3} GB disk, ${written} of ${blocks} blocks written, ${((at + 512) / 1024 ** 2).toFixed(1)} MB`);

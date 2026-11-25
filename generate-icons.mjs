import fs from 'fs';
import path from 'path';

const EAGLE_PATH_D = 'M30,120L41,119L57,102L59,103L58,106L34,132L41,132L47,129L63,108L65,109L65,111L40,144L49,143L54,138L70,113L72,114L46,156L53,155L58,152L78,117L80,118L80,120L62,153L66,153L72,150L86,119L88,120L88,123L76,151L82,150L85,147L95,121L97,122L88,149L95,147L98,143L103,123L105,122L106,126L101,146L107,142L109,131L111,129L116,136L115,140L104,152L104,156L97,164L80,165L80,170L84,166L87,166L88,168L85,171L87,173L87,170L93,166L99,172L101,170L98,166L103,160L109,159L117,154L117,158L97,185L106,183L109,180L114,168L117,167L118,169L108,191L116,189L119,184L121,172L124,169L125,175L123,182L123,191L125,193L130,192L130,195L134,189L131,174L132,169L135,171L137,184L140,189L148,191L138,169L139,167L142,168L147,180L150,183L160,185L138,156L139,154L153,160L158,166L155,170L157,173L157,171L163,166L166,167L170,173L171,171L168,168L169,166L172,166L176,169L176,165L161,165L153,157L153,153L141,139L144,129L146,128L149,142L152,145L156,146L150,125L151,123L154,124L157,139L161,147L168,149L159,124L160,122L162,122L171,147L175,150L180,151L168,123L168,120L170,119L184,150L190,153L194,153L176,120L176,118L178,117L197,151L201,154L209,156L186,120L184,114L187,114L204,141L211,144L216,144L192,113L191,109L194,109L211,131L221,131L197,104L198,102L215,119L226,120L183,76L179,74L165,75L163,77L163,88L160,95L149,102L141,102L138,100L136,80L132,77L123,76L112,81L112,86L115,84L119,84L121,86L121,92L117,101L107,102L102,100L95,93L93,87L93,77L90,74L76,74L72,76Z M145,58L148,61L145,67L150,66L153,70L153,66L158,63L154,61L153,57L151,59Z M98,63L103,65L103,70L107,66L112,67L109,63L111,58L106,59L103,56L103,60Z M121,55L125,59L124,64L128,61L133,64L132,58L136,55L131,55L128,50L126,55Z';

function buildSvg(paddingScale = 0.92) {
  const offset = (256 * (1 - paddingScale)) / 2;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 256 256">
  <defs>
    <radialGradient id="bg" cx="50%" cy="35%" r="75%">
      <stop offset="0%" stop-color="#2a3b36"/>
      <stop offset="100%" stop-color="#131e1d"/>
    </radialGradient>
    <linearGradient id="gold" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#e2d2ba"/>
      <stop offset="55%" stop-color="#cdbaa1"/>
      <stop offset="100%" stop-color="#9a8161"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" fill="url(#bg)"/>
  <g transform="translate(${offset}, ${offset}) scale(${paddingScale})">
    <path d="${EAGLE_PATH_D}" fill="url(#gold)"/>
  </g>
</svg>`;
}

async function run() {
  const dirs = [
    path.resolve(process.cwd(), 'dist/icons'),
    path.resolve(process.cwd(), 'public/icons')
  ];
  for (const d of dirs) fs.mkdirSync(d, { recursive: true });

  const stdSvg = buildSvg(0.92);
  const maskSvg = buildSvg(0.74);

  for (const d of dirs) {
    fs.writeFileSync(path.join(d, 'eagle.svg'), stdSvg, 'utf8');
  }

  try {
    const sharpMod = await import('sharp');
    const sharp = sharpMod.default;
    for (const d of dirs) {
      await sharp(Buffer.from(stdSvg)).resize(192, 192).png({ compressionLevel: 9 }).toFile(path.join(d, 'eagle-192.png'));
      await sharp(Buffer.from(stdSvg)).resize(512, 512).png({ compressionLevel: 9 }).toFile(path.join(d, 'eagle-512.png'));
      await sharp(Buffer.from(maskSvg)).resize(512, 512).png({ compressionLevel: 9 }).toFile(path.join(d, 'eagle-maskable.png'));
    }
    console.log('Generated PNG eagle icons successfully.');
  } catch (err) {
    console.warn('Sharp unavailable, falling back to SVG icons:', err.message);
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});

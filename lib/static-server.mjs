/**
 * Раздача каталога по HTTP — для целей, у которых dev-сервера нет вовсе.
 *
 *   node static-server.mjs <порт> [каталог]
 *
 * Такая цель в хозяйстве одна: лендинг лаунчера. Это статика, которую на
 * проде отдаёт nginx прямо из каталога релиза, — сборки у неё нет, а значит
 * нет и `npm run dev`, за который можно было бы зацепиться.
 *
 * Почему свой файл, а не `npx serve`:
 *   * npx на первом запуске лезет в сеть, и `dk run` переставал бы работать
 *     без интернета — при том что раздать двадцать файлов с диска интернет не
 *     нужен вовсе;
 *   * версия пакета не зафиксирована нигде, то есть поведение локального
 *     запуска зависело бы от того, что реестр отдал сегодня;
 *   * python3 на Windows-машинах разработчиков может не быть, а node есть
 *     всегда: на нём собираются четыре сайта из шести.
 *
 * Это НЕ замена nginx и не претендует на неё: ни сжатия, ни кеширования, ни
 * заголовков безопасности здесь нет. Задача ровно одна — открыть страницу по
 * localhost и увидеть те же файлы, что уедут на сервер.
 */

import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve } from 'node:path';

const port = Number(process.argv[2]);
const root = resolve(process.argv[3] ?? '.');

if (!Number.isInteger(port) || port <= 0 || port > 65535) {
  console.error('static-server: первым аргументом нужен порт');
  process.exit(2);
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
};

const server = createServer(async (req, res) => {
  const path = decodeURIComponent((req.url || '/').split('?')[0]);

  // normalize + проверка префикса: без неё /../../.ssh/id_ed25519 уводил бы
  // раздачу за пределы каталога. Сервер слушает только петлю, но обход
  // каталога — не тот класс ошибок, который стоит заводить даже локально.
  let target = normalize(join(root, path));
  if (!target.startsWith(root)) {
    res.writeHead(403).end('forbidden\n');
    return;
  }

  try {
    let info = await stat(target);
    if (info.isDirectory()) {
      target = join(target, 'index.html');
      info = await stat(target);
    }
    res.writeHead(200, {
      'Content-Type': TYPES[extname(target)] ?? 'application/octet-stream',
      'Content-Length': info.size,
      // Локальная раздача обязана показывать то, что на диске СЕЙЧАС: правку
      // в index.html ищут в браузере, а не в кеше.
      'Cache-Control': 'no-store',
    });
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    createReadStream(target).pipe(res);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end(`404 ${path}\n`);
  }
});

// Только петля: раздаётся каталог рабочего дерева, и открывать его всей сети,
// в которой сидит машина, незачем.
server.listen(port, '127.0.0.1', () => {
  console.log(`статика ${root} → http://localhost:${port}`);
});

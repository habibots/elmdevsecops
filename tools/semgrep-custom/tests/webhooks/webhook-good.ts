import crypto from 'node:crypto';
export async function POST(req: Request) {
  const sig = req.headers.get('x-square-signature');
  const body = await req.text();
  const expected = crypto.createHmac('sha256', process.env.SQUARE_WEBHOOK_KEY!).update(body).digest('base64');
  if (sig !== expected) return new Response('invalid signature', { status: 401 });
  await processWebhook(JSON.parse(body));
  return new Response('ok');
}
async function processWebhook(_data: unknown) { /* ... */ }

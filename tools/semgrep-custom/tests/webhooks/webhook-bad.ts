// Webhook with no signature verification — must fire the rule.
export async function POST(req: Request) {
  const body = await req.json();
  await processWebhook(body);
  return new Response('ok');
}
async function processWebhook(_data: unknown) { /* ... */ }

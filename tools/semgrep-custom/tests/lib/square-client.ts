import { Client } from 'square';
export const squareClient = new Client({
  accessToken: process.env.SQUARE_ACCESS_TOKEN!,
  environment: 'production',
});

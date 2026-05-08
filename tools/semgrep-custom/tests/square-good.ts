// This file uses the wrapper; never touches the env directly.
import { squareClient } from './lib/square-client';
await squareClient.payments.create({ amount: 100, currency: 'USD' });

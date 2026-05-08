// This file is OUTSIDE the wrapper module — must trigger the rule.
const token = process.env.SQUARE_ACCESS_TOKEN;
fetch('https://connect.squareup.com/v2/payments', {
  headers: { Authorization: `Bearer ${token}` },
});

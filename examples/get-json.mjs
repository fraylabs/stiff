import { Http, sendJson } from '../src/node.mjs';

const url = process.argv[2] ?? 'https://httpbin.org/json';
const response = await sendJson(Http.get(url));
console.log(JSON.stringify({ status: response.status, data: response.data }, null, 2));

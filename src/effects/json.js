function json_parse(text) {
  if (typeof host === 'undefined') throw new Error('Use the Stiff Node IO runner: npm run bend -- program.bend');
  return host.parseJson(text);
}

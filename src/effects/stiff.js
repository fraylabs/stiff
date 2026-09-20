// The Stiff runner supplies host; these effects intentionally return promises.
// Upstream's synchronous Bun IO loop cannot execute them.
function stiff_send(request) {
  if (typeof host === 'undefined') throw new Error('Use the Stiff Node IO runner: npm run bend -- program.bend');
  return host.send(request);
}

// Replaces the offline-cache service worker that earlier web builds installed.
// It takes over at once, deletes every cache, unregisters itself and reloads
// open pages, so they fetch the current build from the network.
// Published next to index.html (see the gh-pages publish steps); not part of the export.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
	event.waitUntil((async () => {
		for (const key of await caches.keys()) {
			await caches.delete(key);
		}
		await self.registration.unregister();
		const pages = await self.clients.matchAll({ type: 'window' });
		for (const page of pages) {
			page.navigate(page.url);
		}
	})());
});

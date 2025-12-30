// Torrent content layout: Original
// Default Torrent Management Mode: Automatic
// Default Save Path: /media/torrents/complete
// Incomplete Save Path: /incomplete
import { execSync } from 'child_process';

function fetchIndexers(baseUrl, apiKey, tag) {
  const buffer = execSync(`curl -fsSL "$${baseUrl}/api/v1/tag/detail?apiKey=$${apiKey}"`);
  const response = JSON.parse(buffer.toString("utf8"));
  const indexerIds = response.filter(i => i.label === tag)[0]?.indexerIds ?? [];
  const indexers = indexerIds.map(i => `$${baseUrl}/$${i}/api?apikey=$${apiKey}`);
  console.log(`Loaded $${indexers.length} indexers from Prowlarr`);
  return indexers;
}

export default {
  action: "inject",
  apiKey: process.env.CROSS_SEED_API_KEY,
  linkCategory: "cross-seed",
  linkDirs: ["/media/torrents/complete/cross-seed"],
  linkType: "hardlink",
  matchMode: "partial",
  outputDir: null,
  port: Number(process.env.CROSS_SEED_PORT),
  skipRecheck: true,
  torrentClients: ["qbittorrent:http://qbittorrent.media.svc.cluster.local"],
  torznab: fetchIndexers("http://prowlarr.media.svc.cluster.local", process.env.PROWLARR__AUTH__APIKEY, "cross-seed"),
  useClientTorrents: true,
};

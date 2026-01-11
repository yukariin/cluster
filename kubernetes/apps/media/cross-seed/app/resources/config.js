// Torrent content layout: Original
// Default Torrent Management Mode: Automatic
// Default Save Path: /media/torrents/complete
// Incomplete Save Path: /incomplete
import { execSync } from 'child_process';

function fetchIndexers(baseUrl, apiKey, tag) {
  const buffer = execSync(`curl -fsSL "$${baseUrl}/api/v1/tag/detail?apikey=$${apiKey}"`);
  const response = JSON.parse(buffer.toString('utf8'));
  const indexerIds = response.filter(t => t.label === tag)[0]?.indexerIds ?? [];
  const indexers = indexerIds.map(i => `$${baseUrl}/$${i}/api?apikey=$${apiKey}`);
  console.log(`Loaded $${indexers.length} indexers from Prowlarr`);
  return indexers;
}

export default {
  // Basic
  action: "inject",
  apiKey: process.env.CROSS_SEED_API_KEY,
  includeNonVideos: true,
  includeSingleEpisodes: true,
  rssCadence: "20min",
  skipRecheck: true,
  // Blocklist
  blockList: ["category:manual"],
  // Container
  outputDir: null,
  port: Number(process.env.CROSS_SEED_PORT),
  // Partial Matching
  matchMode: "partial",
  linkCategory: "cross-seed",
  linkDirs: ["/media/torrents/complete/cross-seed"],
  linkType: "hardlink",
  // Searching
  excludeRecentSearch: "3 days",
  excludeOlder: "2 weeks",
  searchCadence: "1 day",
  // ARR searching
  radarr: [`http://radarr.media.svc.cluster.local/?apikey=$${process.env.RADARR__AUTH__APIKEY}`,],
  sonarr: [`http://sonarr.media.svc.cluster.local/?apikey=$${process.env.SONARR__AUTH__APIKEY}`,],
  // Prowlarr
  torznab: fetchIndexers("http://prowlarr.media.svc.cluster.local", process.env.PROWLARR__AUTH__APIKEY, "cross-seed"),
  // Torrent Clients
  torrentClients: ["qbittorrent:http://qbittorrent.media.svc.cluster.local"],
  useClientTorrents: true,
};

// Where the site lives, and the links every page needs.

/** The production host. Policy pages, shared links and the API are the Worker's (Server/). */
export const HOST = "https://dream.onlychan.xyz";

// TODO: the real App Store link, once the app record exists in App Store Connect
// (docs/AppStore.md). This placeholder doesn't open anything yet. Every "Get Dream" button uses it.
export const APP_STORE_URL = "https://apps.apple.com/app/dream/idTODO";

export const LINKS = {
  privacy: `${HOST}/privacy`,
  terms: `${HOST}/terms`,
  support: `${HOST}/support`,
  supportEmail: "support@onlychan.xyz",
  privacyEmail: "privacy@onlychan.xyz",
};

/** What the App Store listing calls Dream (docs/AppStore.md, first choice). */
export const STORE_NAME = "Dream: pages for anything";

/** The App Store promotional text, which doubles as the page's description. */
export const DESCRIPTION =
  "Ask for anything, by typing, speaking or with a photo. Dream makes a page for it: one that explains, works it out, or both, with controls to play with.";

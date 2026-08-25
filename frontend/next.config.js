/** @type {import('next').NextConfig} */
// Static export: every page here is client-side — wagmi talks to public RPCs straight from the
// browser — so there is nothing for a server to do, and a static bundle can be served from
// GitHub Pages off the same public repo as the contracts.
const repo = "airbag-hook";
module.exports = {
  reactStrictMode: true,
  output: "export",
  basePath: process.env.GITHUB_PAGES ? `/${repo}` : "",
  assetPrefix: process.env.GITHUB_PAGES ? `/${repo}/` : "",
  images: { unoptimized: true },
  trailingSlash: true,
};

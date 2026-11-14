import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  cacheComponents: true,
  partialPrefetching: true,
  // Your drops used to have their own address; the start page is that list now.
  // Redirects keep the query, so old sign-in and "added" links still land right.
  async redirects() {
    return [{ source: "/mine", destination: "/", permanent: false }];
  },
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;

// import EleventyI18nPlugin from '@11ty/eleventy';
// import pluginRss from '@11ty/eleventy-plugin-rss';
// import syntaxHighlight from '@11ty/eleventy-plugin-syntaxhighlight';

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export default async function (eleventyConfig) {
  // Content-hash filter for cache-busting asset URLs. Reads the file
  // from src/ at build time and appends ?v=<hash>. Nix normalizes
  // mtime to epoch 0 across rebuilds, so ETag/Last-Modified alone
  // can collide on equal-size edits — a content-derived query string
  // guarantees a fresh URL whenever the file actually changes.
  eleventyConfig.addFilter('assetVersion', (urlPath) => {
    try {
      const filePath = resolve('src', urlPath.replace(/^\//, ''));
      const hash = createHash('sha1')
        .update(readFileSync(filePath))
        .digest('hex')
        .slice(0, 10);
      return `${urlPath}?v=${hash}`;
    } catch (err) {
      return urlPath;
    }
  });
  // eleventyConfig.addPlugin(EleventyI18nPlugin, {
  //   defaultLanguage: 'en',
  //   errorMode: 'allow-fallback',
  // });
  //
  // eleventyConfig.addPlugin(pluginRss);
  //
  // eleventyConfig.addPlugin(syntaxHighlight, {
  //   preAttributes: {
  //     tabindex: 0,
  //   },
  // });

  eleventyConfig.addPassthroughCopy("src/css");
  eleventyConfig.addPassthroughCopy("src/images");
  eleventyConfig.addPassthroughCopy("src/img");
  eleventyConfig.addPassthroughCopy("src/js");

  return {
    htmlTemplateEngine: 'njk',
    markdownTemplateEngine: 'njk',
    dir: {
      input: 'src',
      data: 'data',
      includes: 'includes',
      layouts: 'layouts',
      output: "public",
    },
    pathPrefix: '',
  };
}

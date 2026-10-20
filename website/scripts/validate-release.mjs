#!/usr/bin/env node
import { publication, releases, validateReleases } from "../src/releases.js";
import { site, validateSite } from "../src/site-config.js";

const args = process.argv.slice(2);
const invalid = args.filter((argument) => argument !== "--for-publication");
if (invalid.length > 0) {
  console.error(
    `Unknown option: ${invalid.join(", ")}. Use --for-publication for release checks.`,
  );
  process.exitCode = 2;
} else {
  const forPublication = args.includes("--for-publication");
  const errors = [
    ...validateReleases(releases, {
      requirePublicationApproval: forPublication,
    }),
    ...validateSite(site, { requirePublication: forPublication }),
  ];
  if (errors.length > 0) {
    console.error(
      `Release configuration failed:\n${errors.map((error) => `  - ${error}`).join("\n")}`,
    );
    process.exitCode = 1;
  } else {
    console.log(
      `Release configuration valid. Publication ${publication.approved ? "approved" : "not approved; local preview only"}.`,
    );
    for (const release of releases)
      console.log(`  ${release.name}: ${release.state}`);
    console.log(`  iPhone and iPad: ${site.ios.state}`);
    console.log(`  Site origin: ${site.origin ?? "not chosen"}`);
  }
}

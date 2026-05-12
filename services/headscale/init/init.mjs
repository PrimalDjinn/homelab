// @ts-check
import fs from "node:fs";
import { dirname } from "node:path";

const files = [
  {
    input: process.env.HP_CONFIG_PATH_IN || "/app/headplane_config.yml",
    output: process.env.HP_CONFIG_PATH_OUT || "/shared/headplane_config.yaml",
  },
  {
    input: process.env.HS_CONFIG_PATH_IN || "/app/headscale_config.yml",
    output: process.env.HS_CONFIG_PATH_OUT || "/shared/headscale_config.yaml",
  },
];

function render(value) {
  return value.replace(/\$\{([A-Z0-9_]+)\}/g, (_, key) => process.env[key] ?? "");
}

for (const file of files) {
  if (!fs.existsSync(file.input)) {
    throw new Error(`Missing config template: ${file.input}`);
  }

  fs.mkdirSync(dirname(file.output), { recursive: true });
  const rendered = render(fs.readFileSync(file.input, "utf8"));
  fs.writeFileSync(file.output, rendered);
  console.log(`Rendered ${file.input} -> ${file.output}`);
}

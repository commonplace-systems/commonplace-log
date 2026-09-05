// Fixture-only reimplementation of commonplace-next Identity/Membership at
// 94abc915604cf93ee6c604d33bc2e14ae2d61441. Never import into production.
const namespace = "commonplace-next.organization.";
async function digest(input: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input)));
}
const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
export async function derive(org: string, facet: string, discriminator?: string): Promise<string> {
  const bytes = (await digest(`${namespace}${facet}:${org}${discriminator === undefined ? "" : `:${discriminator}`}`)).slice(0, 16);
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x70;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const id = hex(bytes);
  return `${id.slice(0, 8)}-${id.slice(8, 12)}-${id.slice(12, 16)}-${id.slice(16, 20)}-${id.slice(20)}`;
}
export async function editor(org: string, member: string, generation: number): Promise<string> {
  const epoch = hex(await digest(`commonplace-next.organization.membership.${org}:${member}:${generation}`));
  return derive(org, "editor_cell", epoch);
}
// Literal Elixir-produced vectors from facet_stability_test.exs at the pinned
// source; that test records these as captured before facet retirement at b1842e1.
export const knownOrg = "01990000-0000-7000-8000-00000000000a";
export const known = {
  authority_cell: "8bdd039d-1f22-75b7-bb02-eefa76a9bbac",
  editor_cell: "1d916912-ca42-7fb4-bacf-966bcd8237fb",
  editor_root_directory: "410901ed-9546-7b05-9845-87a5e9bcd0e3",
  owner_membership: "785b246c-0795-7d27-9f4b-be99152e5d42",
  root_directory: "c40583de-df2d-7970-a6c3-199586a801b7",
  seed_document: "429abb11-7d19-7c2a-9bbf-ad5c1fde7d8a",
  session_cell: "5dcc7035-54b0-7ba9-8363-5d240beb9ee7",
  space: "754e1ce2-cd6e-7d37-b32b-3c664453ecb7",
  workspace_cell: "3d949c46-8d39-735a-ac4a-5cb79ba39904",
};

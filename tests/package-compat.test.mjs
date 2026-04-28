import assert from "node:assert/strict";
import fs from "node:fs";

const initSource = fs.readFileSync("src/init.luau", "utf8");
const serverSource = fs.readFileSync("src/Server.luau", "utf8");
const testProject = JSON.parse(fs.readFileSync("test.project.json", "utf8"));
const devProject = JSON.parse(fs.readFileSync("dev.project.json", "utf8"));

assert(
	!/\bServer\s*=\s*require\(script\.Server\)/.test(initSource),
	"src/init.luau must not eagerly require Server from the package entrypoint",
);

assert(
	!/\bClient\s*=\s*require\(script\.Client\)/.test(initSource),
	"src/init.luau must not eagerly require Client from the package entrypoint",
);

assert(
	/serverPackages/i.test(serverSource),
	"src/Server.luau must resolve server-dependencies from a ServerPackages mount",
);

for (const [name, project] of [
	["test.project.json", testProject],
	["dev.project.json", devProject],
]) {
	const packages = project.tree.ReplicatedStorage.Packages;
	const serverPackages = project.tree.ServerScriptService.ServerPackages;

	assert.equal(packages?.$path, "Packages", `${name} must mount Wally Packages with one $path`);
	assert.equal(
		serverPackages?.$path,
		"ServerPackages",
		`${name} must mount Wally ServerPackages with one $path`,
	);
	assert.equal(
		packages.EZProfileStore?.$path,
		"src",
		`${name} should only add the local package alias needed for this repo to test itself`,
	);
	assert(
		!packages._Index,
		`${name} should not hand-wire Wally's dependency _Index; mount Packages directly instead`,
	);
}

const packages = testProject.tree.ReplicatedStorage.Packages;
assert.equal(
	packages.EZProfileStore?.$path,
	"src",
	"test.project.json must expose the local package alias",
);

console.log("package compatibility checks passed");

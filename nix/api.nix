{ pkgs, lib, stdenv, fetchFromGitHub, fetchurl, fetchgit }:
with lib;
let
	_nixpkgs = pkgs;
	utils = rec {
		# sub-tools implemented in their own nix files
		nixImpure = _nixpkgs.callPackage ./nixImpure.nix {};
		importDrv = _nixpkgs.callPackage ./importDrv.nix {};
		exportLocalGit = _nixpkgs.callPackage ./exportLocalGit.nix { inherit nixImpure; };
		overrideSrc = _nixpkgs.callPackage ./overrideSrc.nix { inherit importDrv; };
		unpackArchive = _nixpkgs.callPackage ./unpackArchive.nix {};
	};

	# exposed for testing
	internal = with api; rec {
		makeFetchers = { path }:
			let withRelativePath = fn: args:
				# inject support for `relativePath` as long as
				# we were invoked with a base path
				let
					fullPath = relativePath: (
						if path == null
							then abort "relativePath only supported when using `inject` with a path"
							else "${path}/${relativePath}"
					);

					finalArgs = if args ? relativePath
						then { path = fullPath args.relativePath; } //
							(filterAttrs (n: v: n != "relativePath") args)
						else args;
				in
				fn finalArgs;
			in {
			github = fetchFromGitHub;
			url = fetchurl;
			git = fetchgit;
			git-local = withRelativePath exportLocalGit;
			path = withRelativePath ({ path }: path);
		};

		implAttrPaths = node: map (splitString ".") (node.attrs.attrPaths or [node.name]);

		implAttrset = node: impl:
		let
			paths = implAttrPaths node;
			attrs = map (path: setAttrByPath path impl) paths;
		in
		foldr recursiveUpdate {} attrs;

		makeImport = settings: name: attrs:
			let
				fetchers = makeFetchers settings;
				fetcher = attrs.type;
				fetchArgs = attrs.fetch;
				src = if builtins.hasAttr fetcher fetchers
					then (builtins.getAttr fetcher fetchers) fetchArgs
					else abort "Unknown fetcher: ${fetcher}"
				;
				nixAttr = attrs.nix or null;
				nix = if nixAttr == null then null else "${src}/${nixAttr}";
				version = attrs.version or (fetchArgs.ref or null);

				defaultCall = { pkgs, path }: pkgs.callPackage path {};
				callImpl = attrs.call or defaultCall;

				callWith = args:
					# If attrs.nix == null, we return the source instead of a derivation
					if nix == null
						then builtins.trace "[wrangle] Providing ${name} (source-only) from ${src}" src
						else builtins.trace "[wrangle] Importing ${name} from ${nix}" (overrideSrc {
							inherit src version;
							drv = callImpl args;
						});
				drv = callWith { pkgs = _nixpkgs; path = nix; };
				overlay = (self: super:
					let
						impl = callWith { pkgs = self; path = nix; };
						addition = implAttrset node impl;
						paths = implAttrPaths node;
					in
					recursiveUpdateUntil (path: l: r: elem path paths) super addition
				);
				node = { inherit name attrs src version nix overlay drv; };
			in
			node
		;

		importsOfJson = settings: json: mapAttrs
			(makeImport { path = json.path or null; }) json;
	};

	api = with internal; with utils; utils // (rec {
		inherit internal;

		importJsonSrc = path:
			let attrs = if isAttrs path
				then path
				else builtins.trace "[wrangle] Loading ${path}" (importJSON path);
			in
			assert attrs.wrangle.apiversion == 1; attrs;

		importFrom = {
			path ? null,
			sources ? null,
			extend ? null,
		}:
		let
			jsonList = map importJsonSrc (
				if sources != null then sources else (
					if path == null
						then (abort "path or sources required")
						else (
							let
								p = builtins.toString path;
								candidates = [
									"${p}/wrangle.json"
									"${p}/wrangle-local.json"
								];
								present = filter builtins.pathExists candidates;
							in
							if (length present == 0)
								then lib.warn "No files found in candidates:\n - ${concatStringsSep "\n - " candidates}" present
								else present
						)
				)
			);
			jsonSources = lib.foldr recursiveUpdate { sources = {}; } jsonList;
			jsonExtended = if extend == null then jsonSources else (
				# extend only acts on `sources`, not the full attrset
				recursiveUpdate jsonSources ({ sources = extend jsonSources.sources; })
			);
		in
		# map `sources` into imports instead of plain attrs
		jsonExtended // {
			sources = importsOfJson { inherit path; } jsonExtended.sources;
		};

		overlaysOfImport = imports:
			map (node: node.overlay) (attrValues imports.sources);

		pkgsOfImport = imports: {
			overlays ? [],
			importArgs ? {},
		}:
		import _nixpkgs.path ({
			overlays = (overlaysOfImport imports) ++ overlays;
		} // importArgs);

		pkgs = {
			path ? null,
			sources ? null,

			overlays ? [],
			extend ? null,
			importArgs ? {},
		}:
		pkgsOfImport (importFrom { inherit path sources extend; }) {
			inherit overlays extend importArgs;
		};

		overlays = args: overlaysOfImport (importFrom args);

		derivations = args: mapAttrs (name: node: node.drv) (importFrom args).sources;

		inject = {
			# inject args
			nix,
			provided ? {},
			basePath ? null,

			# callPackage args
			args ? {},

			# importFrom args
			path ? null,
			sources ? null,

			# pkgsOfImport args
			overlays ? [],
			extend ? null,
			importArgs ? {},
		}:
			let
				isPath = p: builtins.typeOf p == "path";
				# if nix _is_ a path, it can act as `path` argument too
				path = if basePath == null && isPath nix then nix else null;
				imports = importFrom { inherit path sources extend; };

				# If explicitly injected with e.g. `nixpkgs` and nix-wrangle, use those
				# instead of reconstructing from source
				injectedDepOverlay = (self: super: filterAttrs (n: v: v != null) provided);

				pkgs = pkgsOfImport imports {inherit importArgs;
					overlays = [injectedDepOverlay] ++ overlays;
				};
				base = pkgs.callPackage nix args;
				selfSrc = imports.sources.self or null;
			in
			(if selfSrc == null then base else
				builtins.trace "[wrangle] injecting src from `self` dependency" (
				let selfImpl = makeImport { inherit path; } selfSrc.name selfSrc.attrs; in
				overrideSrc {
					inherit (selfImpl) src version;
					drv = base;
				})
			);
	});
in api

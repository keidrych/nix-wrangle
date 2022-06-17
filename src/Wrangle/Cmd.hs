{-# LANGUAGE CPP #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

module Wrangle.Cmd where

import Prelude hiding (error)
import Control.Applicative
import Control.Monad
import Control.Monad.Except (throwError)
import Control.Monad.Catch (throwM)
import Control.Monad.State
import Data.Char (toUpper)
import Data.Maybe (fromMaybe)
import Data.List (partition, intercalate, intersperse)
import Data.List.NonEmpty (NonEmpty(..))
import System.Exit (exitFailure)
import Wrangle.Source (PackageName(..), StringMap, asString)
import Wrangle.Util
import Data.Aeson.Key (Key)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.HashMap.Strict as HMap
import qualified Data.Aeson.KeyMap as AMap
import qualified Data.Aeson.Key as Key
import qualified Data.String.QQ as QQ
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as B
import qualified Wrangle.Fetch as Fetch
import qualified Wrangle.Source as Source
import qualified System.Directory as Dir
#ifdef ENABLE_SPLICE
import qualified Wrangle.Splice as Splice
#endif
import qualified Options.Applicative as Opts
import qualified Options.Applicative.Help.Pretty as Doc
import qualified System.FilePath.Posix as PosixPath

main :: IO ()
main = join $ Opts.customExecParser prefs opts where
  opts = Opts.info (parseCommand <**> Opts.helper) $ mconcat desc
  prefs = Opts.prefs Opts.showHelpOnEmpty
  desc =
    [ Opts.fullDesc
    , Opts.header "Nix-wrangle - source & dependency manager for Nix projects"
    ]

parseCommand :: Opts.Parser (IO ())
parseCommand = Opts.subparser (
  Opts.command "init" parseCmdInit <>
  Opts.command "add" parseCmdAdd <>
  Opts.command "rm" parseCmdRm <>
  Opts.command "update" parseCmdUpdate <>
#ifdef ENABLE_SPLICE
  Opts.command "splice" parseCmdSplice <>
#endif
  Opts.command "show" parseCmdShow <>
  Opts.command "ls" parseCmdLs <>
  Opts.command "default-nix" parseCmdDefaultNix
  ) <|> Opts.subparser (
    (Opts.command "installcheck"
      (subcommand "postinstall check" (pure cmdInstallCheck) []))
    <> Opts.internal
  )

subcommand desc action infoMod =
  Opts.info
    (Opts.helper <*> action) $
    mconcat ([
      Opts.fullDesc,
      Opts.progDesc desc
    ] ++ infoMod)

docLines :: [Doc.Doc] -> Doc.Doc
docLines lines = foldr (<>) Doc.empty (intersperse Doc.hardline lines)
softDocLines lines = foldr (<>) Doc.empty (intersperse Doc.softline lines)

examplesDoc ex = Opts.footerDoc $ Just $ docLines ["Examples:", Doc.indent 2 $ docLines ex]

newtype CommonOpts = CommonOpts {
  sources :: Maybe (NonEmpty Source.SourceFile)
} deriving newtype Show

parseCommon :: Opts.Parser CommonOpts
parseCommon =
  build <$> parseSources <*> parseLocal <*> parsePublic
  where
    build src a b = CommonOpts { sources = NonEmpty.nonEmpty (src <> a <> b) }
    parseSources = many $ Source.NamedSource <$> Opts.strOption
      ( Opts.long "source" <>
        Opts.short 's' <>
        Opts.metavar "SOURCE.json" <>
        Opts.help "Specify wrangle.json file to operate on"
      )
    parseLocal = Opts.flag [] [Source.LocalSource]
      ( Opts.long "local" <>
        Opts.help "use nix/wrangle-local.json"
      )
    parsePublic = Opts.flag [] [Source.DefaultSource]
      ( Opts.long "public" <>
        Opts.help "use nix/wrangle.json"
      )

parseName :: Opts.Parser Source.PackageName
parseName = Source.PackageName <$> Opts.argument Opts.str (Opts.metavar "NAME")

parseNames :: Opts.Parser (Maybe (NonEmpty Source.PackageName))
parseNames = NonEmpty.nonEmpty <$> many parseName

(|>) a fn = fn a

lookupAttr :: Key -> StringMap -> (Maybe String, StringMap)
lookupAttr key map = (AMap.lookup key map, map)

consumeAttr :: Key -> StringMap -> (Maybe String, StringMap)
consumeAttr key map = (AMap.lookup key map, AMap.delete key map)

attrRequired :: Key -> String
attrRequired key = "--"<> (Key.toString key) <> " required"

consumeRequiredAttr :: Key -> StringMap -> (Either String String, StringMap)
consumeRequiredAttr key map = require $ consumeAttr key map where
  -- this error message is a little presumptuous...
  require (value, map) = (toRight (attrRequired key) value, map)

type StringMapState a = StateT StringMap (Either String) a

consumeOptionalAttrT :: Key -> StringMapState (Maybe String)
consumeOptionalAttrT key = state $ consumeAttr key

lookupOptionalAttrT :: Key -> StringMapState (Maybe String)
lookupOptionalAttrT key = state $ lookupAttr key

consumeAttrT :: Key -> StringMapState String
consumeAttrT key = StateT consume where
  consume :: StringMap -> Either String (String, StringMap)
  consume = reshape . consumeRequiredAttr key
  reshape (result, map) = (\result -> (result, map)) <$> result

defaultGitRef = "master"

data ParsedAttrs = ParsedAttrs (Maybe Source.PackageName -> StringMap)

extractAttrs :: Maybe Source.PackageName -> ParsedAttrs -> StringMap
extractAttrs nameOpt (ParsedAttrs fn) = fn nameOpt

processAdd :: Maybe PackageName -> Maybe String -> ParsedAttrs -> Either AppError (Maybe PackageName, Source.PackageSpec)
processAdd nameOpt source attrs = mapLeft AppError $ build nameOpt source attrs
  where
    build :: Maybe PackageName -> Maybe String -> ParsedAttrs -> Either String (Maybe PackageName, Source.PackageSpec)
    build nameOpt source parsedAttrs = evalStateT
      (build' nameOpt source)
      (extractAttrs nameOpt parsedAttrs)

    build' :: Maybe PackageName -> Maybe String -> StringMapState (Maybe PackageName, Source.PackageSpec)
    build' nameOpt sourceOpt = typ >>= \case
      Source.FetchGithub -> buildGithub sourceOpt nameOpt
      (Source.FetchUrl urlType) -> withName nameOpt $ buildUrl urlType sourceOpt
      Source.FetchPath -> withName nameOpt $ buildLocalPath sourceOpt
      Source.FetchGitLocal -> withName nameOpt $ buildGitLocal sourceOpt
      Source.FetchGit -> withName nameOpt $ buildGit sourceOpt
      where
        typ :: StringMapState Source.FetchType
        typ = (consumeAttrT "type" <|> pure "github") >>= lift . Source.parseFetchType

    withName :: Maybe PackageName -> StringMapState a -> StringMapState (Maybe PackageName, a)
    withName name = fmap (\snd -> (name, snd))

    packageSpec :: Source.SourceSpec -> StringMapState Source.PackageSpec
    packageSpec sourceSpec = state $ \attrs -> (Source.PackageSpec {
      Source.sourceSpec,
      Source.packageAttrs = attrs,
      Source.fetchAttrs = AMap.empty
    }, AMap.empty)

    buildPathOpt :: StringMapState (Maybe Source.LocalPath)
    buildPathOpt = fmap pathOfString <$> consumeOptionalAttrT "path" where

    buildPath :: Maybe String -> StringMapState Source.LocalPath
    buildPath source =
      buildPathOpt >>= \path -> lift $
        toRight "--path or source required" (path <|> (pathOfString <$> source))

    pathOfString :: String -> Source.LocalPath
    pathOfString path = if PosixPath.isAbsolute path
      then Source.FullPath path
      else Source.RelativePath path

    buildLocalPath :: Maybe String -> StringMapState Source.PackageSpec
    buildLocalPath source = do
      path <- buildPath source
      packageSpec (Source.Path path)

    buildGitCommon :: StringMapState Source.GitCommon
    buildGitCommon = do
      fetchSubmodulesStr <- lookupOptionalAttrT Source.fetchSubmodulesKeyJSON
      fetchSubmodules <- lift $ case fetchSubmodulesStr of
        Just "true" -> Right True
        Just "false" -> Right False
        Nothing -> Right False
        Just other -> Left ("fetchSubmodules: expected Bool, got: " ++ (other))
      return $ Source.GitCommon { Source.fetchSubmodules }

    buildGit :: Maybe String -> StringMapState Source.PackageSpec
    buildGit source = do
      urlArg <- consumeOptionalAttrT "url"
      gitRef <- consumeOptionalAttrT "ref"
      gitUrl <- lift $ toRight
        ("--url or source required")
        (urlArg <|> source)
      gitCommon <- buildGitCommon
      packageSpec $ Source.Git $ Source.GitSpec {
        Source.gitUrl, Source.gitCommon,
        Source.gitRef = Source.Template (gitRef `orElse` defaultGitRef)
      }

    buildGitLocal :: Maybe String -> StringMapState Source.PackageSpec
    buildGitLocal source = do
      glPath <- buildPath source
      ref <- consumeOptionalAttrT "ref"
      glCommon <- buildGitCommon
      packageSpec $ Source.GitLocal $ Source.GitLocalSpec {
        Source.glPath, Source.glCommon,
        Source.glRef = Source.Template <$> ref
      }

    buildUrl :: Source.UrlFetchType -> Maybe String -> StringMapState Source.PackageSpec
    buildUrl urlType source = do
      urlAttr <- consumeOptionalAttrT "url"
      url <- lift $ toRight "--url or souce required" (urlAttr <|> source)
      packageSpec $ Source.Url Source.UrlSpec {
        Source.urlType = urlType,
        Source.url = Source.Template url
      }

    parseGithubSource :: Maybe PackageName -> String -> Either String (PackageName, String, String)
    parseGithubSource name source = case span (/= '/') source of
      (owner, '/':repo) -> Right (fromMaybe (PackageName repo) name, owner, repo)
      _ -> throwError ("`" <> source <> "` doesn't look like a github repo")

    buildGithub :: Maybe String -> Maybe PackageName -> StringMapState (Maybe PackageName, Source.PackageSpec)
    buildGithub source name = do
      (name, ghOwner, ghRepo) <- identity
      ref <- consumeOptionalAttrT "ref"
      ghCommon <- buildGitCommon
      withName (Just name) $ packageSpec $ Source.Github Source.GithubSpec {
        Source.ghOwner,
        Source.ghRepo,
        Source.ghCommon,
        Source.ghRef = Source.Template . fromMaybe "master" $ ref
      }
      where
        explicitSource (owner, repo) = (fromMaybe (PackageName repo) name, owner, repo)

        identity :: StringMapState (PackageName, String, String)
        identity = do
          owner <- consumeOptionalAttrT "owner"
          repo <- consumeOptionalAttrT "repo"
          lift $ buildIdentity owner repo

        buildIdentity :: Maybe String -> Maybe String -> Either String (PackageName, String, String)
        buildIdentity owner repo = case (fromAttrs, fromSource, fromNameAsSource) of
            (Just fromAttrs, Nothing, _) -> Right fromAttrs
            (Nothing, Just fromSource, _) -> fromSource
            (Nothing, Nothing, Just fromName) -> fromName
            (Nothing, Nothing, Nothing) -> throwError "name, source or --owner/--repo required"
            (Just _, Just _, _) -> throwError "use source or --owner/--repo, not both"
          where
            ownerAndRepo :: Maybe (String, String) = (,) <$> owner <*> repo
            fromAttrs :: Maybe (PackageName, String, String) = explicitSource <$> ownerAndRepo
            fromSource = parseGithubSource name <$> source
            fromNameAsSource = parseGithubSource Nothing <$> unPackageName <$> name

parseAdd :: Opts.Parser (Either AppError (PackageName, Source.PackageSpec))
parseAdd = build
    <$> Opts.optional parseName
    <*> Opts.optional parseSource
    <*> parsePackageAttrs ParsePackageAttrsAdd
  where
    parseSource = Opts.argument Opts.str (Opts.metavar "SOURCE")
    build :: Maybe PackageName -> Maybe String -> ParsedAttrs -> Either AppError (PackageName, Source.PackageSpec)
    build nameOpt source attrs = do
      (name, package) <- processAdd nameOpt source attrs
      name <- toRight (AppError "--name required") name
      return (name, package)

data ParsePackageAttrsMode = ParsePackageAttrsAdd | ParsePackageAttrsUpdate | ParsePackageAttrsSplice

parsePackageAttrs :: ParsePackageAttrsMode -> Opts.Parser ParsedAttrs
parsePackageAttrs mode = build <$> many parseAttribute where
  build attrPairs = ParsedAttrs (extractor (AMap.fromList attrPairs)) where
    extractor :: StringMap -> (Maybe Source.PackageName) -> StringMap
    extractor attrs nameOpt = canonicalizeNix $ case mode of
      ParsePackageAttrsAdd -> addDefaultNix nameOpt attrs
      _ -> attrs

    -- drop nix attribute it if it's explicitly `"false"`
    canonicalizeNix attrs = case AMap.lookup key attrs of
      Just "false" -> AMap.delete key attrs
      _ -> attrs
      where key = "nix"

    -- add default nix attribute, unless it's the `self` package
    addDefaultNix nameOpt attrs = case (nameOpt, AMap.lookup key attrs) of
      (Just (Source.PackageName "self"), Nothing) -> attrs
      (_, Just _) -> attrs
      (_, Nothing) -> AMap.insert key defaultDepNixPath attrs
      where key = "nix"

  parseAttribute :: Opts.Parser (Key, String)
  parseAttribute =
    Opts.option (Opts.maybeReader parseKeyVal)
      ( Opts.long "attr" <>
        Opts.short 'a' <>
        Opts.metavar "KEY=VAL" <>
        Opts.help "Set the package spec attribute <KEY> to <VAL>"
      ) <|> shortcutAttributes <|>
    (("type",) <$> Opts.strOption
      ( Opts.long "type" <>
        Opts.short 't' <>
        Opts.metavar "TYPE" <>
        Opts.help ("The source type. "<> Source.validTypesDoc)
      ))

  -- Parse "key=val" into ("key", "val")
  parseKeyVal :: String -> Maybe (Key, String)
  parseKeyVal str = case span (/= '=') str of
    (key, '=':val) -> Just (Key.fromString key, val)
    _ -> Nothing

  -- Shortcuts for known attributes
  shortcutAttributes :: Opts.Parser (Key, String)
  shortcutAttributes = foldr (<|>) empty $ mkShortcutAttribute <$> shortcuts
    where
    shortcuts = case mode of
      ParsePackageAttrsAdd -> allShortcuts
      ParsePackageAttrsUpdate -> allShortcuts
      ParsePackageAttrsSplice -> sourceShortcuts
    allShortcuts = ("nix", "all") : sourceShortcuts
    sourceShortcuts = [
      ("ref", "github / git / git-local"),
      ("fetchSubmodules", "github / git / git-local"),
      ("owner", "github"),
      ("repo", "github"),
      ("url", "url / file / git"),
      ("path", "git-local"),
      ("version", "all")]

  mkShortcutAttribute :: (String, String) -> Opts.Parser (Key, String)
  mkShortcutAttribute (attr, types) =
    (Key.fromString attr,) <$> Opts.strOption
      ( Opts.long attr <>
        Opts.metavar (toUpper <$> attr) <>
        Opts.help
          (
            "Equivalent to --attr " <> attr <> "=" <> (toUpper <$> attr) <>
            ", used for source type " <> types
          )
      )

-------------------------------------------------------------------------------
-- Show
-------------------------------------------------------------------------------
parseCmdShow :: Opts.ParserInfo (IO ())
parseCmdShow = subcommand "Show source details" (cmdShow <$> parseCommon <*> parseNames) []

cmdShow :: CommonOpts -> Maybe (NonEmpty PackageName) -> IO ()
cmdShow opts names =
  do
    sourceFiles <- requireConfiguredSources $ sources opts
    sequence_ $ map showPkgs (NonEmpty.toList sourceFiles) where
      showPkgs :: Source.SourceFile -> IO ()
      showPkgs sourceFile = do
        putStrLn $ " - "<>Source.pathOfSource sourceFile<>":"
        packages <- Source.loadSourceFile sourceFile
        putStrLn $ Source.encodePrettyString (filterPackages names packages)

      filterPackages Nothing p = Source.unPackages p
      filterPackages (Just names) p = HMap.filterWithKey pred (Source.unPackages p) where
        pred name _ = elem name names

parseCmdLs :: Opts.ParserInfo (IO ())
parseCmdLs = subcommand "list sources" (cmdLs <$> parseCommon) []

cmdLs :: CommonOpts -> IO ()
cmdLs opts =
  do
    sourceFiles <- requireConfiguredSources $ sources opts
    sources <- Source.loadSources sourceFiles
    putStrLn $
      intercalate "\n" $
      map (\s -> " - "<> asString s) $
      HMap.keys $ Source.unPackages $
      Source.merge $ sources

requireConfiguredSources :: Maybe (NonEmpty Source.SourceFile) -> IO (NonEmpty Source.SourceFile)
requireConfiguredSources sources =
  Source.configuredSources sources >>=
    (liftMaybe (AppError "No wrangle JSON files found"))

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
data InitOpts = InitOpts {
  nixpkgsChannel :: Maybe String
}
parseCmdInit :: Opts.ParserInfo (IO ())
parseCmdInit = subcommand "Initialize nix-wrangle" (
  cmdInit <$> parseInit) []
  where
    parseInit = Opts.optional (Opts.strOption
      ( Opts.long "pkgs" <>
        Opts.short 'p' <>
        Opts.metavar "CHANNEL" <>
        Opts.help ("Pin nixpkgs to CHANNEL")
      ))

cmdInit :: Maybe String -> IO ()
cmdInit nixpkgs = do
  isGit <- Dir.doesPathExist ".git"
  debugLn $ "isGit ? " <> (show isGit)
  addMultiple OverwriteSource NoAutoInit (Right (wrangleSpec : (selfSpecs isGit ++ nixpkgsSpecs))) commonOpts
  updateDefaultNix defaultNixOptsDefault
  where
    commonOpts = CommonOpts { sources = Nothing }
    wrangleSpec = (PackageName "nix-wrangle", Source.PackageSpec {
      Source.sourceSpec = Source.Github Source.GithubSpec {
        Source.ghOwner = "timbertson",
        Source.ghRepo = "nix-wrangle",
        Source.ghCommon = Source.defaultGitCommon,
        Source.ghRef = Source.Template "v1"
      },
      Source.fetchAttrs = AMap.empty,
      Source.packageAttrs = AMap.fromList [("nix", "nix")]
    })
    nixpkgsSpecs = case nixpkgs of
      Nothing -> []
      Just channel -> [(PackageName "pkgs", Source.PackageSpec {
      Source.sourceSpec = Source.Github Source.GithubSpec {
        Source.ghOwner = "NixOS",
        Source.ghRepo = "nixpkgs-channels",
        Source.ghCommon = Source.defaultGitCommon,
        Source.ghRef = Source.Template channel
      },
      Source.fetchAttrs = AMap.empty,
      Source.packageAttrs = AMap.fromList [("nix", defaultDepNixPath)]
    })]

    selfSpecs isGit =
      if isGit then [
        (PackageName "self", Source.PackageSpec {
          Source.sourceSpec = Source.GitLocal Source.GitLocalSpec {
            Source.glPath = Source.RelativePath ".",
            Source.glRef = Nothing,
            Source.glCommon = Source.defaultGitCommon
          },
          Source.fetchAttrs = AMap.empty,
          Source.packageAttrs = AMap.empty
        })
      ] else []

-------------------------------------------------------------------------------
-- Add
-------------------------------------------------------------------------------

data AddMode = AddSource | OverwriteSource | AddIfMissing

data AutoInit = AutoInit | NoAutoInit

parseCmdAdd :: Opts.ParserInfo (IO ())
parseCmdAdd = subcommand "Add a source" (cmdAdd <$> parseAddMode <*> parseAdd <*> parseCommon)
  [ examplesDoc [
    "nix-wrangle add timbertson/opam2nix-packages",
    "nix-wrangle add pkgs nixos/nixpkgs-channels --ref nixos-unstable",
    "nix-wrangle add pkgs nixos/nixpkgs-channels --ref nixos-unstable",
    "nix-wrangle add pkgs --owner nixos --repo nixpkgs-channels --ref nixos-unstable",
    "nix-wrangle add --type git-local self .."
  ]]
  where
    parseAddMode = Opts.flag AddSource OverwriteSource
      (Opts.long "replace" <> Opts.help "Replace existing source")

addMultiple :: AddMode -> AutoInit -> Either AppError [(PackageName, Source.PackageSpec)] -> CommonOpts -> IO ()
addMultiple addMode autoInit addOpts opts =
  do
    addSpecs <- liftEither $ addOpts
    configuredSources <- Source.configuredSources $ sources opts
    let sourceFile = NonEmpty.head <$> configuredSources
    debugLn $ "sourceFile: " <> show sourceFile
    source <- loadOrInit autoInit sourceFile
    debugLn $ "source: " <> show source
    let (sourceFile, inputSource) = source
    let baseSource = fromMaybe (Source.emptyPackages) inputSource
    modifiedSource <- foldM addSingle baseSource addSpecs
    Dir.createDirectoryIfMissing True $ PosixPath.takeDirectory (Source.pathOfSource sourceFile)
    Source.writeSourceFile sourceFile modifiedSource
  where
    addSingle :: Source.Packages -> (PackageName, Source.PackageSpec) -> IO Source.Packages
    addSingle base (name, inputSpec) = do
      shouldAdd' <- shouldAdd addMode name base
      if shouldAdd' then do
        putStrLn $ "Adding " <> show name <> " // " <> show inputSpec
        spec <- Fetch.prefetch name inputSpec
        return $ Source.add base name spec
      else
        return base

    loadOrInit :: AutoInit -> Maybe Source.SourceFile -> IO (Source.SourceFile, Maybe Source.Packages)
    -- TODO: arrows?
    loadOrInit AutoInit Nothing = do
      let source = Source.DefaultSource
      infoLn $ Source.pathOfSource source <> " does not exist, initializing..."
      cmdInit Nothing
      loadOrInit NoAutoInit (Just source)

    loadOrInit NoAutoInit Nothing = return (Source.DefaultSource, Nothing)

    loadOrInit _ (Just f) = do
      exists <- Source.doesSourceExist f
      loaded <- sequence $ if exists
        then Just $ Source.loadSourceFile f
        else Nothing
      return (f, loaded)

    shouldAdd :: AddMode -> PackageName -> Source.Packages -> IO Bool
    shouldAdd mode name@(PackageName nameStr) existing =
      if Source.member existing name then
        case mode of
          AddSource -> throwM $ AppError $ nameStr <> " already present, use --replace to replace it"
          OverwriteSource -> infoLn ("Replacing existing " <> nameStr) >> return True
          AddIfMissing -> infoLn ("Not replacing existing " <> nameStr) >> return False
      else return True

cmdAdd :: AddMode -> Either AppError (PackageName, Source.PackageSpec) -> CommonOpts -> IO ()
cmdAdd addMode addOpt opts = addMultiple addMode AutoInit ((\x -> [x]) <$> addOpt) opts

-------------------------------------------------------------------------------
-- Rm
-------------------------------------------------------------------------------
parseCmdRm :: Opts.ParserInfo (IO ())
parseCmdRm = subcommand "Remove one or more sources" (cmdRm <$> parseNames <*> parseCommon) []

cmdRm :: Maybe (NonEmpty PackageName) -> CommonOpts -> IO ()
cmdRm maybeNames opts = do
  packageNames <- liftMaybe (AppError "at least one name required") maybeNames
  alterPackagesNamed (Just packageNames) opts updateSingle where
  updateSingle :: Source.Packages -> PackageName -> IO Source.Packages
  updateSingle packages name = do
    infoLn $ " - removing " <> (show name) <> "..."
    return $ Source.remove packages name
      
-------------------------------------------------------------------------------
-- Update
-------------------------------------------------------------------------------
parseCmdUpdate :: Opts.ParserInfo (IO ())
parseCmdUpdate = subcommand "Update one or more sources"
  (cmdUpdate <$> parseNames <*> parsePackageAttrs ParsePackageAttrsUpdate <*> parseCommon)
  [ examplesDoc [
    "nix-wrangle update pkgs --ref nixpkgs-unstable",
    "nix-wrangle update gup --nix nix/"
  ]]

cmdUpdate :: Maybe (NonEmpty PackageName) -> ParsedAttrs -> CommonOpts -> IO ()
cmdUpdate packageNamesOpt parsedAttrs opts =
  alterPackagesNamed packageNamesOpt opts updateSingle where
  updateSingle :: Source.Packages -> PackageName -> IO Source.Packages
  updateSingle packages name = do
    infoLn $ " - updating " <> (show name) <> "..."
    original <- liftEither $ Source.lookup name packages
    debugLn $ "original: " <> show original
    let updateAttrs = extractAttrs (Just name) parsedAttrs
    debugLn $ "updateAttrs: " <> show updateAttrs
    newSpec <- liftEither $ Source.updatePackageSpec original updateAttrs
    fetched <- Fetch.prefetch name newSpec
    if fetched == original
      then infoLn "   ... (unchanged)"
      else return ()
    return $ Source.add packages name fetched

-- shared by update/rm
-- TODO: pass actual source, since it is always Just
processPackagesNamed :: Maybe (NonEmpty PackageName) -> CommonOpts
  -> (Source.SourceFile -> Source.Packages -> [PackageName] -> IO ())-> IO ()
processPackagesNamed packageNamesOpt opts process = do
  sourceFiles <- requireConfiguredSources $ sources opts
  sources <- sequence $ loadSource <$> sourceFiles
  checkMissingKeys (snd <$> sources)
  sequence_ $ traverseSources <$> sources
  where
    checkMissingKeys :: NonEmpty Source.Packages -> IO ()
    checkMissingKeys sources = case missingKeys of
      [] -> return ()
      _ -> fail $ "No such packages: " <> show missingKeys
      where
        (_, missingKeys) = partitionPackageNames $ Source.merge sources

    partitionPackageNames :: Source.Packages -> ([PackageName], [PackageName])
    partitionPackageNames sources = case packageNamesOpt of
      Nothing -> (Source.keys sources, [])
      (Just names) -> partition (Source.member sources) (NonEmpty.toList names)
    
    traverseSources :: (Source.SourceFile, Source.Packages) -> IO ()
    traverseSources (sourceFile, sources) = do
      let (packageNames, _) = partitionPackageNames sources
      debugLn $ "Package names: " <> (show packageNames)
      process sourceFile sources packageNames

-- shared by update/rm
alterPackagesNamed :: Maybe (NonEmpty PackageName) -> CommonOpts -> (Source.Packages -> PackageName -> IO Source.Packages)-> IO ()
alterPackagesNamed packageNamesOpt opts updateSingle =
  processPackagesNamed packageNamesOpt opts $ \sourceFile sources packageNames -> do
    infoLn $ "Updating "<> Source.pathOfSource sourceFile <> " ..."
    updated <- foldM updateSingle sources packageNames
    Source.writeSourceFile sourceFile updated
    
loadSource :: Source.SourceFile -> IO (Source.SourceFile, Source.Packages)
loadSource f = (,) f <$> Source.loadSourceFile f

#ifdef ENABLE_SPLICE
-------------------------------------------------------------------------------
-- Splice
-------------------------------------------------------------------------------
data SpliceOutput = SpliceOutput FilePath | SpliceReplace
data SpliceOpts = SpliceOpts {
  spliceName :: Maybe PackageName,
  spliceAttrs :: StringMap,
  spliceInput :: FilePath,
  spliceOutput :: SpliceOutput,
  spliceUpdate :: Bool
}

parseCmdSplice :: Opts.ParserInfo (IO ())
parseCmdSplice = subcommand "Splice current `self` source into a .nix document"
  (cmdSplice <$> parseSplice <*> parseCommon) [
    Opts.footerDoc $ Just $ docLines [
      softDocLines [
        "This command generates a copy of the input .nix file, with",
        "the `src` attribute replaced with the current fetcher for",
        "the source named `public`."],
      "",
      softDocLines [
        "This allows you to build a standalone",
        ".nix file for publishing (e.g. to nixpkgs itself)" ],
      "",
      softDocLines [
        "If your source does not come from an existing wrangle.json,",
        "you can pass it in explicitly as attributes, like with",
        "`nix-wrangle add` (i.e. --type, --repo, --owner, --url, etc)"]
  ]]
  where
    parseSplice = build <$> parseInput <*> parseOutput <*> parseName <*> parsePackageAttrs ParsePackageAttrsSource <*> parseUpdate where
      build spliceInput spliceOutput spliceName spliceAttrs spliceUpdate =
        SpliceOpts { spliceInput, spliceOutput, spliceName, spliceAttrs, spliceUpdate }
    parseInput = Opts.argument Opts.str (Opts.metavar "SOURCE")
    parseName = Opts.optional (PackageName <$> Opts.strOption
      ( Opts.long "name" <>
        Opts.short 'n' <>
        Opts.metavar "NAME" <>
        Opts.help ("Source name to use (default: public)")
      ))
    parseOutput = explicitOutput <|> replaceOutput
    replaceOutput = Opts.flag' SpliceReplace
      ( Opts.long "replace" <>
        Opts.short 'r' <>
        Opts.help "Overwrite input file"
      )
    explicitOutput = SpliceOutput <$> (Opts.strOption
      ( Opts.long "output" <>
        Opts.short 'o' <>
        Opts.metavar "DEST" <>
        Opts.help ("Destination file")
      ))
    parseUpdate = Opts.flag True False
      ( Opts.long "no-update" <>
        Opts.help "Don't fetch the latest version of `public` before splicing"
      )

cmdSplice :: SpliceOpts -> CommonOpts -> IO ()
cmdSplice (SpliceOpts { spliceName, spliceAttrs, spliceInput, spliceOutput, spliceUpdate}) opts = do
  fileContents <- Splice.load spliceInput
  let expr = Splice.parse fileContents
  expr <- Splice.getExn expr
  -- putStrLn $ show $ expr
  let existingSrcSpans = Splice.extractSourceLocs expr
  srcSpan <- case existingSrcSpans of
    [single] -> return single
    other -> fail $ "No single source found in " ++ (show other)
  self <- getPublic
  debugLn $ "got source: " <> show self
  replacedText <- liftEither $ Splice.replaceSourceLoc fileContents self srcSpan
  Source.writeFileText outputPath replacedText

  where
    outputPath = case spliceOutput of
      SpliceOutput p -> p
      SpliceReplace -> spliceInput

    getPublic :: IO Source.PackageSpec
    getPublic =
      if HMap.null spliceAttrs then do
        sourceFiles <- requireConfiguredSources $ sources opts
        sources <- Source.merge <$> Source.loadSources sourceFiles
        let name = (spliceName `orElse` PackageName "public")
        if spliceUpdate then
          cmdUpdate (Just $ name :| []) HMap.empty opts
        else
          return ()
        liftEither $ Source.lookup name sources
      else do
        -- For splicing, we support a subset of `add` arguments. We don't
        -- accept a name or source, only explicit spliceAttrs
        infoLn $ "Splicing anonymous source from attributes: " <> show spliceAttrs
        self <- liftEither $ snd <$> processAdd Nothing Nothing spliceAttrs
        Fetch.prefetch (PackageName "self") self
#endif
-- ^ ENABLE_SPLICE

-------------------------------------------------------------------------------
-- default-nix
-------------------------------------------------------------------------------
parseCmdDefaultNix :: Opts.ParserInfo (IO ())
parseCmdDefaultNix = subcommand "Generate default.nix"
  (pure cmdDefaultNix) [
    Opts.footerDoc $ Just $
      "Typically this only needs to be done once, though it" <>
      " may be necessary if you have a very old default.nix"
    ]

cmdDefaultNix :: IO ()
cmdDefaultNix = updateDefaultNix (DefaultNixOpts { force = True })

data DefaultNixOpts = DefaultNixOpts {
  force :: Bool
}
defaultNixOptsDefault = DefaultNixOpts { force = False }

updateDefaultNix :: DefaultNixOpts -> IO ()
updateDefaultNix (DefaultNixOpts { force }) = do
  continue <- if force then return True else shouldWriteFile
  if continue then Source.writeFileText path contents
  else infoLn $ "Note: not replacing existing "<>path<>", run `nix-wrangle default-nix` to explicitly override"
  where
    path = "default.nix"
    markerText :: T.Text = "# Note: This file is generated by nix-wrangle"
    contents :: T.Text
    contents = T.unlines [
      markerText,
      "# It can be regenerated with `nix-wrangle default-nix`",
      defaultNixContents ]

    shouldWriteFile :: IO Bool
    shouldWriteFile = do
      exists <- Dir.doesFileExist path
      if exists then
        (T.isInfixOf markerText) <$> TE.decodeUtf8 <$> B.readFile path
      else
        return True

defaultDepNixPath = "default.nix"

defaultNixContents = T.strip [QQ.s|
let
  systemNixpkgs = import <nixpkgs> {};
  fallback = val: dfl: if val == null then dfl else val;
  makeFetchers = pkgs: {
    github = pkgs.fetchFromGitHub;
    url = builtins.fetchTarball;
  };
  fetch = pkgs: source:
    (builtins.getAttr source.type (makeFetchers pkgs)) source.fetch;
  sourcesJson = (builtins.fromJSON (builtins.readFile ./nix/wrangle.json)).sources;
  wrangleJson = sourcesJson.nix-wrangle or (abort "No nix-wrangle entry in nix/wrangle.json");
in
{ pkgs ? null, nix-wrangle ? null, ... }@provided:
let
  _pkgs = fallback pkgs (
    if builtins.hasAttr "pkgs" sourcesJson
    then import (fetch systemNixpkgs sourcesJson.pkgs) {} else systemNixpkgs
  );
  _wrangle = fallback nix-wrangle (_pkgs.callPackage "${fetch _pkgs wrangleJson}/${wrangleJson.nix}" {});
in
(_wrangle.api { pkgs = _pkgs; }).inject { inherit provided; path = ./.; }
|]

cmdInstallCheck :: IO ()
cmdInstallCheck = do
  apiContext <- Fetch.globalApiContext
  let apiPath = Fetch.apiNix apiContext
  infoLn $ "checking for nix API at "<>apiPath
  apiExists <- Dir.doesFileExist apiPath
  if not apiExists
    then exitFailure
    else return ()
  infoLn "ok"

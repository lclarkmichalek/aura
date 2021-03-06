-- Library for handling package dependencies and version conflicts.

{-

Copyright 2012 Colin Woodbury <colingw@gmail.com>

This file is part of Aura.

Aura is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Aura is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Aura.  If not, see <http://www.gnu.org/licenses/>.

-}

module Aura.Dependencies where

import Control.Monad (filterM)
import Text.Regex.PCRE ((=~))
import Data.Maybe (fromJust)
import Data.List (nub)

import Aura.AurConnection (getTrueVerViaPkgbuild)
import Aura.Pacman (pacmanOutput)
import Aura.Languages
import Aura.Settings
import Aura.General

import Utilities (notNull, tripleThrd)
import Bash

-- Returns either a list of error message or the deps to be installed.
getDepsToInstall :: Settings -> [AURPkg] -> 
                    IO (Either [ErrMsg] ([String],[AURPkg]))
getDepsToInstall ss [] = return $ Left [getDepsToInstallMsg1 (langOf ss)]
getDepsToInstall ss pkgs = do
  -- Can this be done with foldM?
  allDeps <- mapM (determineDeps $ langOf ss) pkgs
  let (ps,as,vs) = foldl groupPkgs ([],[],[]) allDeps
  necPacPkgs <- filterM mustInstall ps >>= mapM makePacmanPkg
  necAURPkgs <- filterM (mustInstall . show) as
  necVirPkgs <- filterM mustInstall vs >>= mapM makeVirtualPkg
  let conflicts = getConflicts ss (necPacPkgs,necAURPkgs,necVirPkgs)
  if notNull conflicts
     then return $ Left conflicts
     else do
       let providers  = map (pkgNameOf . fromJust . providerPkgOf) necVirPkgs
           pacmanPkgs = map pkgNameOf necPacPkgs
       return $ Right (nub $ providers ++ pacmanPkgs, necAURPkgs)

-- Returns ([RepoPackages], [AURPackages], [VirtualPackages])
determineDeps :: Language -> AURPkg -> IO ([String],[AURPkg],[String])
determineDeps lang pkg = do
  let globals  = getGlobalVars $ pkgbuildOf pkg
      depNames = getDeps globals "depends" ++ getDeps globals "makedepends"
  (repoPkgNames,aurPkgNames,other) <- divideByPkgType depNames
  aurPkgs       <- mapM makeAURPkg aurPkgNames
  recursiveDeps <- mapM (determineDeps lang) aurPkgs
  let (rs,as,os) = foldl groupPkgs (repoPkgNames,aurPkgs,other) recursiveDeps
  return (nub rs, nub as, nub os)
      where getDeps gs s = case referenceArray gs s of
                             Nothing -> []
                             Just ds -> ds

-- If a package isn't installed, `pacman -T` will yield a single name.
-- Any other type of output means installation is not required. 
mustInstall :: String -> IO Bool
mustInstall pkg = do
  necessaryDeps <- pacmanOutput $ ["-T",pkg]
  return $ length (words necessaryDeps) == 1

-- Questions to be answered in conflict checks:
-- 1. Is the package ignored in `pacman.conf`?
-- 2. Is the version requested different from the one provided by
--    the most recent version?
getConflicts :: Settings -> ([PacmanPkg],[AURPkg],[VirtualPkg]) -> [ErrMsg]
getConflicts settings (ps,as,vs) = rErr ++ aErr ++ vErr
    where rErr     = extract $ map (getPacmanConflicts lang toIgnore) ps
          aErr     = extract $ map (getAURConflicts lang toIgnore) as
          vErr     = extract $ map (getVirtualConflicts lang toIgnore) vs
          extract  = map fromJust . filter (/= Nothing)
          lang     = langOf settings
          toIgnore = ignoredPkgsOf settings

getPacmanConflicts :: Language -> [String] -> PacmanPkg -> Maybe ErrMsg
getPacmanConflicts lang toIgnore pkg = getRealPkgConflicts f lang toIgnore pkg
    where f = getMostRecentVerNum . pkgInfoOf
       
-- Takes `pacman -Si` output as input.
getMostRecentVerNum :: String -> String
getMostRecentVerNum info = tripleThrd match
    where match     = thirdLine =~ ": " :: (String,String,String)
          thirdLine = allLines !! 2  -- Version num is always the third line.
          allLines  = lines info

getAURConflicts :: Language -> [String] -> AURPkg -> Maybe ErrMsg
getAURConflicts lang toIgnore pkg = getRealPkgConflicts f lang toIgnore pkg
    where f = getTrueVerViaPkgbuild . pkgbuildOf

-- Must be called with a (f)unction that yields the version number
-- of the most up-to-date form of the package.
getRealPkgConflicts :: Package a => (a -> String) -> Language -> [String] ->
                       a -> Maybe ErrMsg
getRealPkgConflicts f lang toIgnore pkg
    | isIgnored (pkgNameOf pkg) toIgnore       = Just failMessage1
    | isVersionConflict (versionOf pkg) curVer = Just failMessage2
    | otherwise = Nothing    
    where curVer       = f pkg
          name         = pkgNameOf pkg
          reqVer       = show $ versionOf pkg
          failMessage1 = getRealPkgConflictsMsg2 lang name
          failMessage2 = getRealPkgConflictsMsg1 lang name curVer reqVer

-- This can't be generalized as easily.
getVirtualConflicts :: Language -> [String] -> VirtualPkg -> Maybe ErrMsg
getVirtualConflicts lang toIgnore pkg
    | providerPkgOf pkg == Nothing = Just failMessage1
    | isIgnored provider toIgnore  = Just failMessage2
    | isVersionConflict (versionOf pkg) pVer = Just failMessage3
    | otherwise = Nothing
    where name         = pkgNameOf pkg
          ver          = show $ versionOf pkg
          provider     = pkgNameOf . fromJust . providerPkgOf $ pkg
          pVer         = getProvidedVerNum pkg
          failMessage1 = getVirtualConflictsMsg1 lang name
          failMessage2 = getVirtualConflictsMsg2 lang name provider
          failMessage3 = getVirtualConflictsMsg3 lang name ver provider pVer

getProvidedVerNum :: VirtualPkg -> String
getProvidedVerNum pkg = splitVer match
    where match = info =~ ("[ ]" ++ pkgNameOf pkg ++ ">?=[0-9.]+")
          info  = pkgInfoOf . fromJust . providerPkgOf $ pkg

-- Compares a (r)equested version number with a (c)urrent up-to-date one.
-- The `MustBe` case uses regexes. A dependency demanding version 7.4
-- SHOULD match as `okay` against version 7.4, 7.4.0.1, or even 7.4.0.1-2.
isVersionConflict :: VersionDemand -> String -> Bool
isVersionConflict Anything _     = False
isVersionConflict (LessThan r) c = not $ comparableVer c < comparableVer r
isVersionConflict (MustBe r) c   = not $ c =~ ("^" ++ r)
isVersionConflict (AtLeast r) c  | comparableVer c > comparableVer r = False
                                 | isVersionConflict (MustBe r) c = True
                                 | otherwise = False

{-|

The environment used by "Typechecker.Typechecker". Contains a
class table and a list of local name-type bindings and
typevar-type bindings for doing lookups, as well as the
'Typechecker.TypeError.Backtrace' used for error handling.

-}

module Typechecker.Environment(Environment,
                               emptyEnv,
                               buildEnvironment,
                               traitLookup,
                               refTypeLookup,
                               refTypeLookupUnsafe,
                               methodAndCalledTypeLookup,
                               fieldLookup,
                               capabilityLookup,
                               varLookup,
                               isLocal,
                               typeVarLookup,
                               extendEnvironment,
                               addParams,
                               addTypeParameters,
                               typeParameters,
                               locals,
                               replaceLocals,
                               bindTypes,
                               bindings,
                               backtrace,
                               currentMethod,
                               pushBT,
                               refTypeParameters
                               ) where

import Data.List
import Data.Maybe
import Control.Applicative ((<|>))
import Control.Monad
import Data.Map (Map)
import qualified Data.Map as Map
import Text.Printf (printf)

-- Module dependencies
import Identifiers
import AST.AST hiding(showWithKind)
import Types
import Typechecker.TypeError

type VarTable    = [(Name, Type)]

data Environment = Env {
  typeSynonymTable :: Map String Typedef,
  classTable :: Map String ClassDecl,
  traitTable :: Map String TraitDecl,
  globals  :: VarTable,
  locals   :: VarTable,
  bindings :: [(Type, Type)],
  typeParameters :: [Type],
  bt :: Backtrace
} deriving Show

emptyEnv = Env {
  typeSynonymTable = Map.empty,
  classTable = Map.empty,
  traitTable = Map.empty,
  globals = [],
  locals = [],
  bindings = [],
  typeParameters = [],
  bt = emptyBT
}

buildEnvironment :: Environment -> Program -> (Either TCError Environment, [TCWarning])
buildEnvironment env p = (return $ mergeEnvs env (buildEnvironment' p), [])
  where
    buildEnvironment' :: Program -> Environment
    buildEnvironment' Program {typedefs, functions, classes, traits, imports} =
        Env {
           typeSynonymTable = Map.fromList [(getId (typedefdef t), t) | t <- typedefs],
           classTable = Map.fromList [(getId (cname c), c) | c <- classes],
           traitTable = Map.fromList [(getId (tname t), t) | t <- traits],
           globals = map getFunctionType functions,
           locals = [],
           bindings = [],
           typeParameters = [],
           bt = emptyBT}

    getFunctionType f =
        let funname   = functionName f
            funparams = functionParams f
            funtypeparams = functionTypeParams f
            funtype   = functionType f
        in
          (funname, arrowWithTypeParam funtypeparams (map ptype funparams) funtype)


mergeEnvs :: Environment -> Environment -> Environment
mergeEnvs Env{classTable     = classTable,
              traitTable     = traitTable,
              typeSynonymTable = typeSynonymTable,
              globals        = globs,
              locals         = locals,
              bindings       = binds,
              typeParameters = tparams,
              bt             = bt}
          Env{classTable     = classTable',
              traitTable     = traitTable',
              typeSynonymTable = typeSynonymTable',
              globals        = globs',
              locals         = locals',
              bindings       = binds',
              typeParameters = tparams',
              bt             = bt'} =
       Env{classTable     = Map.union classTable classTable',
           traitTable     = Map.union traitTable traitTable',
           typeSynonymTable = Map.union typeSynonymTable typeSynonymTable',
           globals        = globs ++ globs',
           locals         = locals ++ locals',
           bindings       = binds ++ binds',
           typeParameters = tparams ++ tparams',
           bt             = emptyBT}

pushBT :: Pushable a => a -> Environment -> Environment
pushBT x env@Env{bt} = env{bt = push x bt}

backtrace = bt

currentMethod :: Environment -> Maybe MethodDecl
currentMethod = currentMethodFromBacktrace . bt

formalBindings :: Type -> Type -> [(Type, Type)]
formalBindings formal actual
    | isRefAtomType formal && isRefAtomType actual =
        let formals = getTypeParameters formal
            actuals = getTypeParameters actual
        in
          zip formals actuals
    | otherwise =
        error $ "Environment.hs: Tried to get bindings from " ++
                showWithKind formal ++ " and " ++ showWithKind actual

fieldLookup :: Type -> Name -> Environment -> Maybe FieldDecl
fieldLookup ty f env
  | isTraitType ty = do
    trait <- traitLookup ty env
    fld <- find ((== f) . fname) $ requiredFields trait
    let bindings = formalBindings (tname trait) ty
        ftype' = replaceTypeVars bindings $ ftype fld
    return fld{ftype = ftype'}
  | isClassType ty = do
    cls <- classLookup ty env
    fld <- find ((== f) . fname) $ cfields cls
    let bindings = formalBindings (cname cls) ty
        ftype' = replaceTypeVars bindings $ ftype fld
    return fld{ftype = ftype'}
  | otherwise = error $ "Trying to lookup field in a non ref type " ++ show ty

matchHeader :: Name -> FunctionHeader -> Bool
matchHeader m = (==m) . hname

traitMethodLookup :: Type -> Name -> Environment -> Maybe FunctionHeader
traitMethodLookup ty m env = do
  trait <- traitLookup ty env
  let headers = requiredMethods trait ++ map mheader (tmethods trait)
      bindings = formalBindings (tname trait) ty
  header <- find (matchHeader m) headers
  return $ replaceHeaderTypes bindings header

classMethodLookup :: Type -> Name -> Environment -> Maybe FunctionHeader
classMethodLookup ty m env = do
  cls <- classLookup ty env
  let headers = map mheader $ cmethods cls
      bindings = formalBindings (cname cls) ty
      tys = typesFromCapability $ ccapability cls
      classResults = find (matchHeader m) headers
      traitResults = msum (map (\ty -> traitMethodLookup ty m env) tys)
  header <- classResults <|> traitResults
  return $ replaceHeaderTypes bindings header

methodAndCalledTypeLookup ::
    Type -> Name -> Environment -> Maybe (FunctionHeader, Type)
methodAndCalledTypeLookup ty m env
    | isCapabilityType ty = do
        let traits = typesFromCapability ty
            results = map (\t -> (traitMethodLookup t m env, t)) traits
        (ret, ty') <- find (isJust . fst) results
        return (fromJust ret, ty')
    | isUnionType ty = do
        let members = unionMembers ty
        mapM_ (\t -> methodLookup t m env) members
        methodAndCalledTypeLookup (head members) m env
    | otherwise = do
        ret <- methodLookup ty m env
        return (ret, ty)

methodLookup :: Type -> Name -> Environment -> Maybe FunctionHeader
methodLookup ty m env
  | isClassType ty =
    classMethodLookup ty m env
  | isTraitType ty =
    traitMethodLookup ty m env
  | isCapabilityType ty = do
    let traits = typesFromCapability ty
        ms = map (\t -> traitMethodLookup t m env) traits
    ret <- find isJust ms
    return $ fromJust ret
  | otherwise = Nothing

capabilityLookup :: Type -> Environment -> Maybe Type
capabilityLookup ty env
    | isClassType ty = do
        cls <- Map.lookup (getId ty) $ classTable env
        let bindings = formalBindings (cname cls) ty
        return $ replaceTypeVars bindings $ ccapability cls
    | otherwise = error $ "Environment.hs: Tried to look up the capability " ++
                          "of non-class type " ++ show ty

traitLookup :: Type -> Environment -> Maybe TraitDecl
traitLookup t env =
  Map.lookup (getId t) $ traitTable env

classLookup :: Type -> Environment -> Maybe ClassDecl
classLookup cls env
    | isRefAtomType cls = Map.lookup (getId cls) $ classTable env
    | isTypeSynonym cls = classLookup (unfoldTypeSynonyms cls) env -- TODO: remove!!
    | otherwise = error $
      "Tried to lookup the class of '" ++ show cls
      ++ "' which is not a reference type"

refTypeLookup :: Type -> Environment -> Maybe Type
refTypeLookup t env =
  let
    typeSyn = fmap typedefdef $ Map.lookup (getId t) $ typeSynonymTable env
    cls = fmap cname $ Map.lookup (getId t) $ classTable env
    trait = fmap tname $ Map.lookup (getId t) $ traitTable env
  in
    cls <|> trait <|> typeSyn

refTypeLookupUnsafe :: Type -> Environment -> Type
refTypeLookupUnsafe t env =
  let
    ret = refTypeLookup t env
    found = isJust ret
  in
    if found then
      fromJust ret
    else
      error $ printf "Can't find ref type %s" $ show t

refTypeParameters :: Type -> Environment -> [Type]
refTypeParameters t env =
  let Just t' = refTypeLookup t env
  in getTypeParameters t'

varLookup :: Name -> Environment -> Maybe Type
varLookup x env = case lookup x (locals env) of
                       Nothing -> lookup x (globals env)
                       result -> result

isLocal :: Name -> Environment -> Bool
isLocal x env = isJust $ lookup x (locals env)

typeVarLookup :: Type -> Environment -> Maybe Type
typeVarLookup ty env
    | isTypeVar ty =
        lookup ty (bindings env) <|>
        find (==ty) (typeParameters env)
    | otherwise    = error
      "Tried to lookup the binding of something that was not a type variable"

extendEnvironment :: [(Name, Type)] -> Environment -> Environment
extendEnvironment [] env = env
extendEnvironment ((name, ty):newTypes) env =
    extendEnvironment newTypes $ env {locals = extend (locals env) name ty}
    where
      extend [] name' ty' = [(name', ty')]
      extend ((name, ty):locals) name' ty'
          | name == name' = (name', ty') : locals
          | otherwise     = (name, ty) : extend locals name' ty'

-- | Convenience function for extending the environment with a
-- list of parameter declarations
addParams :: [ParamDecl] -> Environment -> Environment
addParams = extendEnvironment . map (\(Param {pname, ptype}) -> (pname, ptype))

addTypeParameters :: [Type] -> Environment -> Environment
addTypeParameters [] env = env
addTypeParameters xs env@(Env{typeParameters}) =
  if all isTypeVar xs then
    env{typeParameters = xs ++ typeParameters}
  else
    error $ printf "'%s' is not a type parameter" $
      show $ head $ filter (not.isTypeVar) xs

bindType :: Type -> Type -> Environment -> Environment
bindType var ty env
    | isTypeVar var = env {bindings = (var, ty) : bindings env}
    | otherwise     = error "Tried to bind something that was not a type variable"

bindTypes :: [(Type, Type)] -> Environment -> Environment
bindTypes bindings env = foldr (\(tyVar, ty) env -> bindType tyVar ty env) env bindings

replaceLocals :: VarTable -> Environment -> Environment
replaceLocals newTypes env = env {locals = newTypes}

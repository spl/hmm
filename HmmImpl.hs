{-
TODO list, roughly in order of preference:

 - functionality: add mmComputeProofTree, together with a ProofTree data
   type, for use by a future HmmCalc module for computing calculational
   proofs

 - performance: store active variables etc. in the context, instead of looking
   them up every time

 - functionality: verifier should give more detail on what went wrong: no call
   to "error" anymore on any input file (and add tests to check wrong input).
   Idea: use an 'error stack': error X because Y because Z

 - readability: tuck special try/mmpSeparator stuff in new combinator.

 - functionality: support for include files ($[ ... $])

 - typechecking: replace type synonyms by 'newtype'.

 - readability: interleave this code with the relevant parts of the Metamath
   specification

 - functionality: support and ignore proofs containing a '?'
-}




module HmmImpl

where

import Text.ParserCombinators.Parsec
import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.List(sort)
import Data.Char(isSpace,isAscii,isControl)


type MMParser a = CharParser Context a

data Database = Database [(Bool, Statement)]
	deriving (Eq, Show)

type Statement = (Label, Expression, StatementInfo)

data StatementInfo = DollarE | DollarF | Axiom [Statement] DVRSet | Theorem [Statement] DVRSet Proof
	deriving (Eq, Show, Ord)


--NOTE: a DVRSet never may contain two identical strings!
type DVRSet = Set.Set DVR
data DVR = DVR String String
	deriving Show

instance Eq DVR where
	DVR v1 w1 == DVR v2 w2 = (v1,w1) == (v2,w2) || (v1,w1) == (w2,v2)

instance Ord DVR where
	DVR v1 w1 <= DVR v2 w2 = (v1 `min` w1, v1 `max` w1) <= (v2 `min` w2, v2 `max` w2)

duplicateDVRs :: DVRSet -> [String]
duplicateDVRs s = [x | DVR x y <- Set.toList s, x == y]

dvrApplySubstitution :: Substitution -> DVRSet -> DVRSet
dvrApplySubstitution subst s = Set.fromList (concat
			[ [DVR v w | v <- varsOf e, w <- varsOf f] |
				((x, e), (y, f)) <- allPairs subst,
				DVR x y `Set.member` s 
				])

dvrSelectOnlyVars :: [String] -> DVRSet -> DVRSet
dvrSelectOnlyVars v s = Set.filter (\(DVR x y) -> x `elem` v && y `elem` v) s


data Symbol = Var String | Con String
	deriving (Eq, Show, Ord)

type Expression = [Symbol]
type Label = String
type Proof = [Statement]

dbEmpty :: Database
dbEmpty = Database []

dbWith:: Database -> Database -> Database
Database ss1 `dbWith` Database ss2 = Database (ss1++ss2)

selectMandatoryDVRSetFor :: Expression -> Database -> Context -> DVRSet
selectMandatoryDVRSetFor symbols db ctx = dvrSelectOnlyVars mandatoryVars (ctxDVRSet ctx)
	where
		mandatoryVars = activeDollarEVars db ++ varsOf symbols

selectMandatoryStatementsForVarsOf :: Expression -> Database -> [Statement]
selectMandatoryStatementsForVarsOf symbols db@(Database ss) =
	[stat |
		(act, stat@(_, syms, info)) <- ss,
		act,
		case info of
			DollarE -> True
			DollarF -> let [Con _c, Var v] = syms in
				v `elem` (activeDollarEVars db ++ varsOf symbols)
			_ -> False
	]

activeDollarEVars :: Database -> [String]
activeDollarEVars (Database ss) =
	concat [varsOf syms |
		(act, (_, syms, info)) <- ss,
		act,
		info == DollarE
	]

varsOf :: Expression -> [String]
varsOf [] = []
varsOf (Var v : rest) = v : varsOf rest
varsOf (Con _c : rest) = varsOf rest


isAssertion :: Statement -> Bool
isAssertion (_, _, Theorem _ _ _) = True
isAssertion (_, _, Axiom _ _) = True
isAssertion _ = False



data Context = Context
	{ctxConstants :: [String]
	,ctxVariables :: [String]
	,ctxDVRSet :: DVRSet
	,ctxActiveHyps :: [Statement]
	,ctxActiveStatements :: Map.Map Label Statement
	}
	deriving Show

instance Eq Context where
	c1 == c2 =
		sort (ctxConstants c1) == sort (ctxConstants c2)
		&& sort (ctxVariables c1) == sort (ctxVariables c2)
		&& ctxDVRSet c1 == ctxDVRSet c2
		&& ctxActiveHyps c1 == ctxActiveHyps c2
		&& ctxActiveStatements c1 == ctxActiveStatements c2

ctxEmpty :: Context
ctxEmpty = Context
	{ctxConstants = []
	,ctxVariables = []
	,ctxDVRSet = Set.empty
	,ctxActiveHyps = []
	,ctxActiveStatements = Map.empty
	}

ctxWithConstants :: Context -> [String] -> Context
ctx `ctxWithConstants` cs = ctx {ctxConstants = cs ++ ctxConstants ctx}

ctxWithVariables :: Context -> [String] -> Context
ctx `ctxWithVariables` vs = ctx {ctxVariables = vs ++ ctxVariables ctx}

ctxWithDVRSet :: Context -> DVRSet -> Context
ctx `ctxWithDVRSet` ds = ctx {ctxDVRSet = ctxDVRSet ctx `Set.union` ds}

ctxWithActiveHyps :: Context -> [Statement] -> Context
ctx `ctxWithActiveHyps` hs = ctx {ctxActiveHyps = ctxActiveHyps ctx ++ hs}

ctxWithStatement :: Context -> Statement -> Context
ctx `ctxWithStatement` s@(l, _, _) = ctx {ctxActiveStatements = Map.insert l s (ctxActiveStatements ctx)}

ctxWithStatements :: Context -> [Statement] -> Context
ctxWithStatements ctx ss = foldl ctxWithStatement ctx ss




mmParseFromFile:: String -> IO (Either String (Context, Database))
mmParseFromFile path = do
		contents <- readFile path
		return (mmParse path contents)

mmParseFromString :: String -> Either String (Context, Database)
mmParseFromString s = mmParse "<string>" s

mmParse :: String -> String -> Either String (Context, Database)
mmParse source s = case runParser mmpDatabase ctxEmpty source s of
			Left err -> Left (show err)
			Right result -> Right result


mmpDatabase :: MMParser (Context, Database)
mmpDatabase = do
		try mmpSeparator <|> return ()
		setState ctxEmpty
		db <- mmpStatements dbEmpty
		eof
		ctx <- getState
		return (ctx, db)

mmpStatements :: Database -> MMParser Database
mmpStatements db =
		do
			dbstat <- mmpStatement db
			let db2 = db `dbWith` dbstat
			(do
				mmpSeparator
				dbstats <- mmpStatements db2
				return (dbstat `dbWith` dbstats)
			 <|> return dbstat)
		<|> return dbEmpty

mmpStatement :: Database -> MMParser Database
mmpStatement db =
		(   ((  mmpConstants
		    <|> mmpVariables
		    <|> mmpDVRs
		    ) >> return (Database []))
		<|> mmpDollarE
		<|> mmpDollarF
		<|> mmpAxiom db
		<|> mmpTheorem db
		<|> mmpBlock db
		) <?> "statement"

mmpSeparator :: MMParser ()
mmpSeparator = do
		many1 ((space >> return ()) <|> mmpComment)
		return ()

mmpComment :: MMParser ()
mmpComment = do
		try (string "$(")
		manyTill anyChar (try (space >> string "$)"))
		return ()
	    <?> "comment"

mmpConstants :: MMParser ()
mmpConstants = do
		mmpTryUnlabeled "$c"
		mmpSeparator
		cs <- mmpSepListEndBy mmpIdentifier "$."
		ctx <- getState
		setState (ctx `ctxWithConstants` cs)
		return ()

mmpVariables :: MMParser ()
mmpVariables = do
		mmpTryUnlabeled "$v"
		mmpSeparator
		cs <- mmpSepListEndBy mmpIdentifier "$."
		ctx <- getState
		setState (ctx `ctxWithVariables` cs)
		return ()

mmpDVRs :: MMParser ()
mmpDVRs = do
		mmpTryUnlabeled "$d"
		mmpSeparator
		d <- mmpSepListEndBy mmpIdentifier "$."
		let dvrSet = Set.fromList (map (\(x, y) -> DVR x y) (allPairs d))
		let dup = duplicateDVRs dvrSet
		if dup == []
			then return ()
			else error ("found same variable(s) " ++ show dup ++ " multiple times in $d")
		ctx <- getState
		setState (ctx `ctxWithDVRSet` dvrSet)
		return ()

mmpDollarE :: MMParser Database
mmpDollarE = do
		lab <- mmpTryLabeled "$e"
		mmpSeparator
		ss <- mmpSepListEndBy mmpIdentifier "$."
		ctx <- getState
		let stat = (lab, mapSymbols ctx ss, DollarE)
		setState (ctx `ctxWithStatement` stat)
		return (Database [(True, stat)])

mmpDollarF :: MMParser Database
mmpDollarF = do
		lab <- mmpTryLabeled "$f"
		mmpSeparator
		c <- mmpIdentifier
		mmpSeparator
		v <- mmpIdentifier
		mmpSeparator
		string "$."
		ctx <- getState
		let stat = (lab, mapSymbols ctx [c, v], DollarF)
		setState (ctx `ctxWithStatement` stat)
		return (Database [(True, stat)])

mmpAxiom :: Database -> MMParser Database
mmpAxiom db = do
		lab <- mmpTryLabeled "$a"
		mmpSeparator
		ss <- mmpSepListEndBy mmpIdentifier "$."
		ctx <- getState
		let symbols = mapSymbols ctx ss
		let mandatoryStatements = selectMandatoryStatementsForVarsOf symbols db
		let stat = (lab, symbols, Axiom mandatoryStatements (selectMandatoryDVRSetFor symbols db ctx))
		setState (ctx `ctxWithStatement` stat)
		return (Database [(True, stat)])

mmpTheorem :: Database -> MMParser Database
mmpTheorem db = do
		lab <- mmpTryLabeled "$p"
		mmpSeparator
		ss <- mmpSepListEndBy mmpIdentifier "$="
		mmpSeparator
		ctx <- getState
		let symbols = mapSymbols ctx ss
		let mandatoryStatements = selectMandatoryStatementsForVarsOf symbols db
		proof <- (mmpUncompressedProof <|> mmpCompressedProof mandatoryStatements)
		let stat = (lab, symbols, Theorem mandatoryStatements (selectMandatoryDVRSetFor symbols db ctx) proof)
		setState (ctx `ctxWithStatement` stat)
		return (Database [(True, stat)])

mmpUncompressedProof :: MMParser Proof
mmpUncompressedProof = do
		labelList <- mmpSepListEndBy mmpLabel "$."
		ctx <- getState
		return (map (findActiveStatement ctx) labelList)

mmpCompressedProof :: [Statement] -> MMParser Proof
mmpCompressedProof mandatoryStatements = do
		string "("
		mmpSeparator
		assertionLabels <- mmpSepListEndBy mmpLabel ")"
		mmpSeparator
		markedNumbers <- mmpCompressedNumbers
		ctx <- getState
		return (createProof assertionLabels markedNumbers ctx)
	where
		createProof :: [Label] -> [(Int,Bool)] -> Context -> Proof
		createProof assertionLabels markedNumbers ctx2 = proof
			where
				proof :: Proof
				proof = proof' markedNumbers ([], [], [])

				-- The meaning of the accumulated arguments:
				-- marked:        the 1st, 2nd, ... marked subproofs
				-- subproofStack: the stack of subproofs, starting with the top of the stack
				-- prf:           the proof resulting from all markedNumbers processed so far
				proof' :: [(Int, Bool)] -> ([Proof], [Proof], Proof) -> Proof
				proof' [] (_, _, p) = p
				proof' ((n, mark):rest) (marked, subproofStack, p) = proof' rest (newMarked, newSubproofStack, newPrf)
					where
						-- meaning !! n =
						--	(the subproof associated with number n
						--	,the number of proof steps that it pops from the proof stack
						--	)
						meaning :: [(Proof, Int)]
						meaning =
							map (\stat -> ([stat], 0)) mandatoryStatements
							++ map (\lab -> (let stat = findActiveStatement ctx2 lab
										in ([stat], length (getHypotheses stat))))
								assertionLabels
							++ zip marked (repeat 0)

						nrPopped :: Int
						newSteps :: Proof
						(newSteps, nrPopped) = meaning !! n

						newSubproof :: Proof
						newSubproof = concat (reverse (take nrPopped subproofStack)) ++ newSteps

						newMarked :: [Proof]
						newMarked = if mark then marked ++ [newSubproof] else marked

						newSubproofStack :: [Proof]
						newSubproofStack = newSubproof : drop nrPopped subproofStack

						newPrf :: Proof
						newPrf = p ++ newSteps

mmpCompressedNumbers :: MMParser [(Int, Bool)]
mmpCompressedNumbers = do
		markedNumbers <- manyTill
			(do
				n <- mmpCompressedNumber
				marked <- try ((try mmpSeparator <|> return ()) >> (((oneOf "Z") >> return True) <|> return False))
				return (n, marked)
			)
			(try ((try mmpSeparator <|> return ()) >> string "$."))
		-- now we work around a bug in an earlier version of the
		-- official Metamath program, which used to encode 140 as UVA
		-- instead of UUA
		let numbers = map fst markedNumbers
		let hackedNumbers = if 140 `elem` numbers && not (120 `elem` numbers)
					then map (\n -> if n >= 140 then n - 20 else n) numbers
					else numbers
		let hackedMarkedNumbers = zip hackedNumbers (map snd markedNumbers)
		return hackedMarkedNumbers

-- NOTE: this function parses A=0, as opposed to A=1 as in the Metamath book
mmpCompressedNumber :: MMParser Int
mmpCompressedNumber = do
		base5 <- many (do
			c <- try ((try mmpSeparator <|> return ()) >> satisfy (\c -> 'U' <= c && c <= 'Y')) <?> "U...Y"
			return (fromEnum c - fromEnum 'U' + 1)
			)
		base20 <- do
			c <- try ((try mmpSeparator <|> return ()) >> satisfy (\c -> 'A' <= c && c <= 'T')) <?> "A...T"
			return (fromEnum c - fromEnum 'A' + 1)
		return (foldl (\x y -> x * 5 + y) 0 base5 * 20 + base20 - 1)

mmpBlock :: Database -> MMParser Database
mmpBlock db = do
		mmpTryUnlabeled "${"
		mmpSeparator
		ctx <- getState
		db2 <- mmpStatements db
		setState (ctx `ctxWithStatements` filter isAssertion (case db2 of Database d -> map snd d))
		string "$}"
		return (deactivateNonAssertions db2)
	where
		deactivateNonAssertions :: Database -> Database
		deactivateNonAssertions (Database ss) =
			Database
				[(newact, (lab, symbols, info)) |
					(act, stat@(lab, symbols, info)) <- ss,
					let newact = if isAssertion stat then act else False
				]

mmpTryUnlabeled :: String -> MMParser ()
mmpTryUnlabeled keyword = (try (string keyword) >> return ()) <?> (keyword ++ " keyword")

mmpTryLabeled :: String -> MMParser Label
mmpTryLabeled keyword = (try $ do
				lab <- mmpLabel
				mmpSeparator
				string keyword
				return lab
			) <?> ("labeled " ++ keyword ++ " keyword")

mmpSepListEndBy :: MMParser a -> String -> MMParser [a]
mmpSepListEndBy p end = manyTill (do {s <- p; mmpSeparator; return s}) (try (string end))

mmpIdentifier :: MMParser String
mmpIdentifier = many1 (satisfy isMathSymbolChar) <?> "math symbol"

mmpLabel :: MMParser Label
mmpLabel = many1 (alphaNum <|> oneOf "-_.")

isMathSymbolChar :: Char -> Bool
isMathSymbolChar c = isAscii c && not (isSpace c) && not (isControl c)

mapSymbols :: Context -> [String] -> Expression
mapSymbols ctx = map $ \s ->
			if s `elem` ctxConstants ctx then Con s
			else if s `elem` ctxVariables ctx then Var s
			else error ("Unknown math symbol " ++ s)


mmComputeTheorem :: Database -> Proof -> Either String (Expression, DVRSet)
mmComputeTheorem db proof = case foldProof db proof combine of
				Right [th] -> Right th
				Right stack -> Left ("proof produced not one theorem but stack " ++ show stack)
				Left err -> Left ("error: " ++ err)
	where
		combine :: Statement -> [(Statement, (Expression, DVRSet))] -> Either String (Expression, DVRSet)
		combine stat labSymsList = case subst' of
						Right _ -> if dup == []
								then Right (newExpr, newDVRSet)
								else Left ("found duplicate disjoint variable(s) " ++ show dup)
						Left err -> Left ("no substitution found: " ++ err)
			where
				(_, expr, _) = stat
				
				subst' = unify (map (\((_, ex, _), (ss, _)) -> (ex, ss)) labSymsList)
				subst = fromRight subst'

				newExpr = case labSymsList of [] -> expr; _ -> applySubstitution subst expr

				{-
				   In the following definition we compute the DVRSet on top of the stack as
				   follows:

				    (1) First we collect all DVRs of the hypotheses that are popped off the
				    stack.

				    (2) We add the DVRs of the assertion that we are processing, after
				    applying the substitution to it.

				    (3) We select only those DVRs that occur in the new expression on top
				    of the stack.

				   The last step makes sure that no optional disjoint variable restrictions
				   are needed for a proof.  This gives the verifier better performance,
				   because we don't have to store the optional restrictions for any
				   assertion.  It also makes this verifier less strict than the official
				   Metamath program, which requires all optional restrictions that are used
				   thoughout a proof.
				-}

				newDVRSet = dvrSelectOnlyVars (varsOf newExpr)
						(hypDVRSet `Set.union` dvrApplySubstitution subst (getDVRs stat))
				hypDVRSet = Set.unions (map (\(_, (_, d)) -> d) labSymsList)


				dup = duplicateDVRs newDVRSet

foldProof :: Show a => Database -> Proof -> (Statement -> [(Statement, a)] -> Either String a) -> Either String [a]
foldProof db labs f = foldProof' db labs f []

foldProof' :: Show a => Database -> Proof -> (Statement -> [(Statement, a)] -> Either String a) -> [a] -> Either String [a]
foldProof' _ [] _ stack = Right stack
foldProof' db (stat:stats) f stack = case newTop' of
					Left err -> Left ("could not apply assertion " ++ show lab ++ " (" ++ show (length stats + 1) ++ "th from the right in the proof) to the top " ++ show nHyps ++ " stack entries " ++ show pairs ++ ": " ++ err)
					Right newTop -> foldProof' db stats f (newTop:poppedStack)
	where
		(lab, _, _) = stat
		hyps = getHypotheses stat
		nHyps = length hyps
		poppedStack = drop nHyps stack
		newTop' = f stat pairs
		pairs = zip hyps (reverse (take nHyps stack))
		--TODO: check that the stack has enough entries!


type Substitution = [(String, Expression)]

unify :: [(Expression, Expression)] -> Either String Substitution
unify tuples = unify' tuples []

unify' :: [(Expression, Expression)] -> Substitution -> Either String Substitution
unify' [] subst = Right subst
unify' (([Con c1, Var v], Con c2 : syms):tuples) subst | c1 == c2 && lookup v subst == Nothing =
	unify' tuples ((v, syms) : subst)
unify' ((fromSyms, toSyms) : tuples) subst
	| computedToSyms == toSyms = unify' tuples subst
	| True = Left ("partial substitution " ++ show subst ++ " does not turn " ++ show fromSyms ++ " into " ++ show toSyms ++ " but into " ++ show computedToSyms)
	where computedToSyms = applySubstitution subst fromSyms

applySubstitution :: Substitution -> Expression -> Expression
applySubstitution subst expr = applySubstitution' subst expr

applySubstitution' :: Substitution -> Expression -> Expression
applySubstitution' _ [] = []
applySubstitution' subst (Con c : rest) = Con c : applySubstitution' subst rest
applySubstitution' subst (Var v : rest) =
	(case lookup v subst of Just ss -> ss; Nothing -> error "impossible")
	++ applySubstitution' subst rest


mmVerifiesLabel :: Database -> Label -> Either String ()
mmVerifiesLabel db lab = case mmVerifiesProof db proof expr dvrSet of
				Left err -> Left ("proof of " ++ show lab ++ ": " ++ err)
				Right () -> Right ()
	where
		stat = findStatement db lab
		(_, expr, Theorem _ dvrSet proof) = stat

mmVerifiesProof :: Database -> Proof -> Expression -> DVRSet -> Either String ()
mmVerifiesProof db proof expr dvrSet = case mmComputeTheorem db proof of
	Right (computedExpr, computedDVRSet) -> if computedExpr == expr
					then let
						violated = computedDVRSet `Set.difference` dvrSet
						in if Set.null violated
							then Right ()
							else Left ("missing dvrSet: " ++ show violated)
					else Left ("proved " ++ show computedExpr ++ " instead of " ++ show expr)
	Left err -> Left ("failed to verify proof " ++ show proof ++ ":" ++ err)

mmVerifiesAll :: Database -> [(Label, Either String ())]
mmVerifiesAll db@(Database stats) =
	map (\(lab, proof, expr, dvrSet) -> (lab, mmVerifiesProof db proof expr dvrSet)) (selectProofs (map snd stats))
	where
		selectProofs :: [Statement] -> [(Label, Proof, Expression, DVRSet)]
		selectProofs [] = []
		selectProofs ((lab, expr, Theorem _ dvrSet proof):rest) =
			(lab, proof, expr, dvrSet) : selectProofs rest
		selectProofs (_:rest) = selectProofs rest

mmVerifiesDatabase :: Database -> Bool
mmVerifiesDatabase db = all (\(_, res) -> case res of Left _ -> False; Right _ -> True) (mmVerifiesAll db)

findStatement :: Database -> Label -> Statement
findStatement (Database []) lab = error $ "statement labeled " ++ lab ++ " not found in database"
findStatement (Database ((_, stat@(lab2, _, _)):rest)) lab
	| lab == lab2	= stat
	| True		= findStatement (Database rest) lab

findActiveStatement :: Context -> Label -> Statement
findActiveStatement ctx lab = case Map.lookup lab (ctxActiveStatements ctx) of
					Just stat -> stat
					Nothing -> error $ "statement labeled " ++ lab ++ " not found in context"

getHypotheses :: Statement -> [Statement]
getHypotheses (_, _, Axiom hyp _) = hyp
getHypotheses (_, _, Theorem hyp _ _) = hyp
getHypotheses _ = []

getDVRs :: Statement -> DVRSet
getDVRs (_, _, Axiom _ d) = d
getDVRs (_, _, Theorem _ d _) = d
getDVRs _ = Set.empty

allPairs :: [a] -> [(a, a)]
allPairs [] = []
allPairs (a:as) = [(a, a2) | a2 <- as] ++ allPairs as

fromRight :: Show a => Either a b -> b
fromRight (Right b) = b
fromRight (Left a) = error ("impossible" ++ show a)

{-
TODO list, roughly in order of preference:

 - readability: clean up code for handling disjoints

 - functionality: verifier should give more detail on what went wrong: no call
   to "error" anymore on any input file (and add tests to check wrong input).

 - performance: add a Data.Map Label Statement in the Context, to quickly
   find them during parsing of compressed proofs

 - performance: instead of Labels, store the Statements in the Database
   structure (i.e., replace lookups by pointers)

 - performance: store active variables etc. in the context, instead of looking
   them up every time

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
import Data.List(sort,(\\),nub)
import Data.Char(isSpace,isAscii,isControl)


type MMParser a = CharParser Context a

data Database = Database [Statement]
	deriving (Eq, Show)

type Statement = (Bool, Label, Expression, StatementInfo)

data StatementInfo = DollarE | DollarF | Axiom [Label] Disjoints | Theorem [Label] Disjoints Proof
	deriving (Eq, Show, Ord)

--NOTE: a Disjoints never may contain a pair of identical strings!
newtype Disjoints = Disjoints [(String,String)]
	deriving (Show, Ord)

instance Eq Disjoints where
	Disjoints d1 == Disjoints d2 = sort (nub (map sortPair d1)) == sort (nub (map sortPair d2))

data Symbol = Var String | Con String
	deriving (Eq, Show, Ord)

type Expression = [Symbol]
type Label = String
type Proof = [String]

dbEmpty :: Database
dbEmpty = Database []

dbWith:: Database -> Database -> Database
Database ss1 `dbWith` Database ss2 = Database (ss1++ss2)

selectMandatoryDisjointsFor :: Expression -> Database -> Context -> Disjoints
selectMandatoryDisjointsFor symbols db ctx = Disjoints ds
	where
		ds = [d |
			d@(x, y) <- case ctxDisjoints ctx of Disjoints ds2 -> ds2,
			x `elem` mandatoryVars,
			y `elem` mandatoryVars
			]
		mandatoryVars = activeDollarEVars db ++ varsOf symbols

selectMandatoryLabelsForVarsOf :: Expression -> Database -> [Label]
selectMandatoryLabelsForVarsOf symbols db@(Database ss) =
	[lab |
		(act, lab, syms, info) <- ss,
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
		(act, _, syms, info) <- ss,
		act,
		info == DollarE
	]

varsOf :: Expression -> [String]
varsOf [] = []
varsOf (Var v : rest) = v : varsOf rest
varsOf (Con _c : rest) = varsOf rest


isAssertion :: Statement -> Bool
isAssertion (_, _, _, Theorem _ _ _) = True
isAssertion (_, _, _, Axiom _ _) = True
isAssertion _ = False



data Context = Context {ctxConstants::[String], ctxVariables::[String], ctxDisjoints::Disjoints}
	deriving Show

instance Eq Context where
	c1 == c2 =
		sort (ctxConstants c1) == sort (ctxConstants c2)
		&& sort (ctxVariables c1) == sort (ctxVariables c2)
		&& sort (case ctxDisjoints c1 of Disjoints d -> map sortPair d)
			== sort (case ctxDisjoints c2 of Disjoints d -> map sortPair d)

ctxEmpty :: Context
ctxEmpty = Context {ctxConstants = [], ctxVariables = [], ctxDisjoints = Disjoints []}

ctxWithConstants :: Context -> [String] -> Context
ctx `ctxWithConstants` cs = ctx {ctxConstants = cs ++ ctxConstants ctx}

ctxWithVariables :: Context -> [String] -> Context
ctx `ctxWithVariables` vs = ctx {ctxVariables = vs ++ ctxVariables ctx}

ctxWithDisjoints :: Context -> [(String, String)] -> Context
ctx `ctxWithDisjoints` ds = ctx {ctxDisjoints = Disjoints (ds ++ case ctxDisjoints ctx of Disjoints d -> d)}





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
		    <|> mmpDisjoints
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

mmpDisjoints :: MMParser ()
mmpDisjoints = do
		mmpTryUnlabeled "$d"
		mmpSeparator
		d <- mmpSepListEndBy mmpIdentifier "$."
		let pairs = allPairs d
		if samePairs pairs
			then error ("found same variable twice in $d " ++ show d)
			else return ()
		ctx <- getState
		setState (ctx `ctxWithDisjoints` pairs)
		return ()

mmpDollarE :: MMParser Database
mmpDollarE = do
		lab <- mmpTryLabeled "$e"
		mmpSeparator
		ss <- mmpSepListEndBy mmpIdentifier "$."
		ctx <- getState
		return (Database [(True, lab, mapSymbols ctx ss, DollarE)])

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
		return (Database [(True, lab, mapSymbols ctx [c, v], DollarF)])

mmpAxiom :: Database -> MMParser Database
mmpAxiom db = do
		lab <- mmpTryLabeled "$a"
		mmpSeparator
		ss <- mmpSepListEndBy mmpIdentifier "$."
		ctx <- getState
		let symbols = mapSymbols ctx ss
		return (Database [(True, lab, symbols, Axiom (selectMandatoryLabelsForVarsOf symbols db) (selectMandatoryDisjointsFor symbols db ctx))])

mmpTheorem :: Database -> MMParser Database
mmpTheorem db = do
		lab <- mmpTryLabeled "$p"
		mmpSeparator
		ss <- mmpSepListEndBy mmpIdentifier "$="
		mmpSeparator
		ctx <- getState
		let symbols = mapSymbols ctx ss
		let mandatoryLabels = selectMandatoryLabelsForVarsOf symbols db
		ps <- (mmpUncompressedProof <|> mmpCompressedProof db mandatoryLabels)
		return (Database [(True, lab, symbols, Theorem mandatoryLabels (selectMandatoryDisjointsFor symbols db ctx) ps)])

mmpUncompressedProof :: MMParser Proof
mmpUncompressedProof = do
		mmpSepListEndBy mmpLabel "$."

mmpCompressedProof :: Database -> [Label] -> MMParser Proof
mmpCompressedProof db mandatoryLabels = do
		string "("
		mmpSeparator
		assertionLabels <- mmpSepListEndBy mmpLabel ")"
		mmpSeparator
		markedNumbers <- mmpCompressedNumbers
		return (createProof assertionLabels markedNumbers)
	where
		createProof :: [Label] -> [(Int,Bool)] -> Proof
		createProof assertionLabels markedNumbers = proof
			where
				proof :: Proof
				proof = proof' markedNumbers ([], [], [])

				-- The meaning of the accumulated arguments:
				-- marked: the 1st, 2nd, ... marked subproofs
				-- subs:   the subproofs ending at the 1st, 2nd, ... number in the list
				-- p:      the proof resulting from all markedNumbers processed so far
				proof' :: [(Int, Bool)] -> ([Proof], [Proof], Proof) -> Proof
				proof' [] (_, _, p) = p
				proof' ((n, mark):rest) (marked, subs, p) = proof' rest (newMarked, newSubs, newP)
					where
						-- meaning !! n =
						--	(the subproof associated with number n
						--	,the number of proof steps that it pops from the proof stack
						--	)
						meaning :: [(Proof, Int)]
						meaning =
							map (\lab -> ([lab], 0)) mandatoryLabels
							++ map (\lab -> ([lab], length (getHypotheses (findStatement db lab))))
								assertionLabels
							++ zip marked (repeat 0)

						newSteps :: Proof
						newSteps = fst (meaning !! n)

						newSub :: Proof
						newSub = concat ((reverse . take (snd (meaning !! n)) . reverse) subs)
							++ newSteps

						newMarked :: [Proof]
						newMarked = if mark then marked ++ [newSub] else marked

						newSubs :: [Proof]
						newSubs = (reverse . drop (snd (meaning !! n)) . reverse) subs
							++ [newSub]

						newP :: Proof
						newP = p ++ newSteps

mmpCompressedNumbers :: MMParser [(Int, Bool)]
mmpCompressedNumbers = do
		markedNumbers <- manyTill
			(do
				n <- mmpCompressedNumber
				marked <- try ((try mmpSeparator <|> return ()) >> (((oneOf "Z") >> return True) <|> return False))
				return (n, marked)
			)
			(try ((try mmpSeparator <|> return ()) >> string "$."))
		-- now we work around a bug in the official Metamath program, which encodes 140 as UVA instead of UUA
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
		setState ctx
		string "$}"
		return (deactivateNonAssertions db2)
	where
		deactivateNonAssertions :: Database -> Database
		deactivateNonAssertions (Database ss) =
			Database
				[(newact, lab, symbols, info) |
					stat@(act, lab, symbols, info) <- ss,
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


mmComputeTheorem :: Database -> Proof -> Either String (Expression, Disjoints)
mmComputeTheorem db proof = case foldProof db proof combine of
				Right [th] -> Right th
				Right stack -> Left ("proof produced not one theorem but stack " ++ show stack)
				Left err -> Left ("error: " ++ err)
	where
		combine :: Statement -> [(Label, (Expression, Disjoints))] -> Either String (Expression, Disjoints)
		combine stat labSymsList = case subst' of
						Right _ -> Right (newSyms, Disjoints newDisjointsList)
						Left err -> Left ("no substitution found: " ++ err)
			where
				(_, _, syms, info) = stat
				disjoints = case info of
					Theorem _ (Disjoints d) _ -> d
					Axiom _ (Disjoints d) -> d
					_ -> []
				subst' = unify (map (\(lab, (ss, _)) -> (findExpression db lab, ss)) labSymsList)
				subst = fromRight subst'
				newSyms = case labSymsList of [] -> syms; _ -> applySubstitution subst syms
				disjointsList = concat (map (\(_, (_, Disjoints d)) -> d) labSymsList)
				newDisjointsList' = disjointsList
							++ concat [ [(v, w) | v <- varsOf e, w <- varsOf f] |
								((x, e), (y, f)) <- allPairs subst,
								sortPair (x, y) `elem` map sortPair disjoints
								]
				newDisjointsList = [(x, y) |
							(x, y) <- newDisjointsList',
							{-
							   The following line makes sure that no optional
							   disjoint variable restrictions are needed for
							   a proof.  This gives the verifier better
							   performance, because we don't have to store the
							   optional restrictions for any assertion.  It
							   also makes this verifier less strict than
							   the official Metamath program, which requires
							   all optional restrictions that are used
							   thoughout a proof.
							-}
							x `elem` varsOf newSyms && y `elem` varsOf newSyms,
							if x == y then error "disjoint violation" else True
							]

foldProof :: Show a => Database -> Proof -> (Statement -> [(Label, a)] -> Either String a) -> Either String [a]
foldProof db labs f = foldProof' db labs f []

foldProof' :: Show a => Database -> Proof -> (Statement -> [(Label, a)] -> Either String a) -> [a] -> Either String [a]
foldProof' _ [] _ stack = Right stack
foldProof' db (lab:labs) f stack = case newTop' of
					Left err -> Left ("could not apply assertion " ++ show lab ++ " (" ++ show (length labs + 1) ++ "th from the right in the proof) to the top " ++ show nHyps ++ " stack entries " ++ show pairs ++ ": " ++ err)
					Right newTop -> foldProof' db labs f (newTop:poppedStack)
	where
		stat = findStatement db lab
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
mmVerifiesLabel db lab = case mmVerifiesProof db proof expr disjoints of
				Left err -> Left ("proof of " ++ show lab ++ ": " ++ err)
				Right () -> Right ()
	where
		stat = findStatement db lab
		(_, _, expr, Theorem _ disjoints proof) = stat

mmVerifiesProof :: Database -> Proof -> Expression -> Disjoints -> Either String ()
mmVerifiesProof db proof expr disjoints = case mmComputeTheorem db proof of
	Right (cExpr, cDisjoints) -> if cExpr == expr
					then let
						violated = sort (nub (map sortPair cD)) \\ sort (nub (map sortPair d))
						Disjoints cD = cDisjoints
						Disjoints d = disjoints
						in if violated == [] 
							then Right ()
							else Left ("missing disjoints: " ++ show violated)
					else Left ("proved " ++ show cExpr ++ " instead of " ++ show expr)
	Left err -> Left ("failed to verify proof " ++ show proof ++ ":" ++ err)

mmVerifiesAll :: Database -> [(Label, Either String ())]
mmVerifiesAll db@(Database stats) =
	map (\(lab, proof, expr, disjoints) -> (lab, mmVerifiesProof db proof expr disjoints)) (selectProofs stats)
	where
		selectProofs :: [Statement] -> [(Label, Proof, Expression, Disjoints)]
		selectProofs [] = []
		selectProofs ((_, lab, expr, Theorem _ disjoints proof):rest) =
			(lab, proof, expr, disjoints) : selectProofs rest
		selectProofs (_:rest) = selectProofs rest

mmVerifiesDatabase :: Database -> Bool
mmVerifiesDatabase db = all (\(_, res) -> case res of Left _ -> False; Right _ -> True) (mmVerifiesAll db)

findStatement :: Database -> Label -> Statement
findStatement (Database []) lab = error $ "statement labeled " ++ lab ++ " not found"
findStatement (Database (stat@(_, lab2, _, _):rest)) lab
	| lab == lab2	= stat
	| True		= findStatement (Database rest) lab

findExpression :: Database -> Label -> Expression
findExpression db lab = syms
	where
		(_, _, syms, _) = findStatement db lab

getHypotheses :: Statement -> [Label]
getHypotheses (_, _, _, Axiom hyp _) = hyp
getHypotheses (_, _, _, Theorem hyp _ _) = hyp
getHypotheses _ = []


allPairs :: [a] -> [(a, a)]
allPairs [] = []
allPairs (a:as) = [(a, a2) | a2 <- as] ++ allPairs as

samePairs :: Eq a => [(a,a)] -> Bool
samePairs = any (\(x,y) -> x == y)

sortPair :: Ord a => (a, a) -> (a, a)
sortPair (x,y)	| x <= y = (x,y)
		| True   = (y,x)

fromRight :: Show a => Either a b -> b
fromRight (Right b) = b
fromRight (Left a) = error ("impossible" ++ show a)

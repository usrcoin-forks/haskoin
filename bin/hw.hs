module Main where

import System.IO
import System.Posix.Env
import System.Posix.Files
import System.Posix.Directory
import qualified System.Environment as E
import System.Console.GetOpt

import Control.Monad
import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Trans.Resource
import Control.Exception

import Data.Maybe
import Data.Char
import Data.Word
import qualified Data.ByteString as BS

import Haskoin.Wallet
import Haskoin.Wallet.Store
import Haskoin.Script
import Haskoin.Protocol
import Haskoin.Crypto
import Haskoin.Util

data Options = Options
    { optCount    :: Int
    , optIndex    :: Word32
    , optInternal :: Bool
    , optRequire  :: Int
    , optSigHash  :: SigHash
    , optHelp     :: Bool
    , optVersion  :: Bool
    } deriving (Eq, Show)

defaultOptions = Options
    { optCount    = 5
    , optIndex    = 0
    , optInternal = False
    , optRequire  = 2
    , optSigHash  = SigAll False
    , optHelp     = False
    , optVersion  = False
    } 

data Command = CmdInit
             | CmdListAddr
             | CmdGenAddr
             | CmdDumpKey
             | CmdDecodeTx
             | CmdBuildTx
             | CmdSignTx
             deriving (Eq, Show)

strToCmd :: String -> Command
strToCmd str = case str of
    "init"     -> CmdInit
    "listaddr" -> CmdListAddr
    "genaddr"  -> CmdGenAddr
    "dumpkey"  -> CmdDumpKey
    "decodetx" -> CmdDecodeTx
    "buildtx"  -> CmdBuildTx
    "signtx"   -> CmdSignTx
    _ -> error $ "Invalid command: " ++ str

options :: [OptDescr (Options -> IO Options)]
options =
    [ Option ['c'] ["count"] (ReqArg parseCount "INT") $
        "Address generation count. Implies address command"
    , Option ['i'] ["index"] (ReqArg parseIndex "INT") $
        "Address key index. Implies address ot dumpwif command"
    , Option ['N'] ["internal"]
        (NoArg $ \opts -> return opts{ optInternal = True }) $
        "Use internal address chain. Implies address or dumpwif command"
    , Option ['r'] ["require"] (ReqArg parseRequire "INT") $
        "Number of required keys (M) when generating M of N addresses"
    , Option ['H'] ["sighash"] (ReqArg parseSigHash "SIGHASH") $
        "Type of signature. Can be ALL|NONE|SINGLE"
    , Option ['A'] ["anyonecanpay"]
        (NoArg $ \opts -> do
            let sh = optSigHash opts
            return opts{ optSigHash = sh{ anyoneCanPay = True } }
        ) $ "Sign a transaction with the AnyoneCanPay flag set"
    , Option ['h'] ["help"]
        (NoArg $ \opts -> return opts{ optHelp = True }) $
        "Display this help message"
    , Option ['v'] ["version"]
        (NoArg $ \opts -> return opts{ optVersion = True }) $
        "Display wallet version information"
    ]

parseCount :: String -> Options -> IO Options
parseCount s opts 
    | res > 0   = return opts{ optCount = res }
    | otherwise = error $ "Invalid count option: " ++ s
    where res = read s

parseIndex :: String -> Options -> IO Options
parseIndex s opts 
    | res >= 0 && res < 0x80000000 = return opts{ optIndex = res }
    | otherwise = error $ "Invalid index option: " ++ s
    where res = read s

parseRequire :: String -> Options -> IO Options
parseRequire s opts 
    | res >= 1 && res <= 16 = return opts{ optRequire = res }
    | otherwise = error $ "Invalid require option (between 1 and 16): " ++ s
    where res = read s

parseSigHash :: String -> Options -> IO Options
parseSigHash s opts = return opts{ optSigHash = res }
    where acp = anyoneCanPay $ optSigHash opts
          res | s == "ALL" = SigAll acp
              | s == "NONE" = SigNone acp
              | s == "SINGLE" = SigSingle acp
              | otherwise = error "Invalid SigHash. Has to be ALL|NONE|SINGLE"

usageHeader :: String
usageHeader = "Usage: hw [<options>] <command> [<args>]"

cmdHelp :: String
cmdHelp = 
    "Valid <command>: \n" 
 ++ "  init <seed>       Initialize a new wallet from a seed\n" 
 ++ "  listaddr [acc]    List addresses in your account\n" 
 ++ "  genaddr [acc]     Generate new addresses for your account\n"
 ++ "  dumpkey [acc]     Dump account key to stdout\n"
 ++ "  decodetx <tx>     Decode a transaction in HEX format\n"
 ++ "  buildtx [(txid,index)] [(addr,amount)] Build a new transaction\n"

warningMsg :: String
warningMsg = "\n**This software is experimental. " 
    ++ "Use only small amounts of Bitcoins**\n"

versionMsg :: String
versionMsg = "haskoin wallet version 0.1.1.0"

usage :: String
usage = warningMsg ++ "\n" ++ usageInfo usageHeader options ++ cmdHelp

main :: IO ()
main = do
    args <- E.getArgs
    case getOpt Permute options args of
        (o,n,[]) -> do
            opts <- foldl (>>=) (return defaultOptions) o
            process opts n
        (_,_,msgs) ->
            error $ concat msgs ++ usageInfo usageHeader options

-- Get Haskoin home directory
getHome :: IO FilePath
getHome = do
    haskoinHome <- getEnv "HASKOIN_HOME" 
    if isJust haskoinHome 
        then return $ fromJust haskoinHome
        else do
            home <- getEnv "HOME"
            unless (isJust home) $ error $
                "Please set $HASKOIN_HOME or $HOME environment variables" 
            return $ fromJust home

-- Create and get Haskoin working directory
getWorkDir :: IO FilePath
getWorkDir = do
    home <- getHome
    let haskoinDir = home ++ "/.haskoin"
        walletDir  = haskoinDir ++ "/wallet"
    e1 <- fileExist haskoinDir
    unless e1 $ createDirectory haskoinDir ownerModes
    e2 <- fileExist walletDir
    unless e2 $ do
        createDirectory walletDir ownerModes
        putStrLn $ "Haskoin working directory created: " ++ walletDir
    return walletDir

process :: Options -> [String] -> IO ()
process opts cs 
    -- -h and -v can be called without a command
    | optHelp opts = putStrLn usage
    | optVersion opts = putStrLn versionMsg
    -- otherwise require a command
    | null cs = putStrLn usage
    | otherwise = getWorkDir >>= \dir -> do
        let (c,args) = (strToCmd $ head cs, tail cs)
        putStrLn warningMsg
        runResourceT $ runWalletDB dir $ case c of
            CmdInit     -> cmdInit opts args
            CmdListAddr -> cmdListAddr opts args
            CmdGenAddr  -> cmdGenAddr opts args
            CmdDumpKey  -> cmdDumpKey args
            CmdDecodeTx -> cmdDecodeTx opts args
            CmdBuildTx  -> cmdBuildTx opts args
            CmdSignTx   -> liftIO $ putStrLn "Command not implemented"
            
type Args = [String]
type CmdAction = WalletDB (ResourceT IO) ()

cmdInit :: Options -> Args -> CmdAction
cmdInit opts args
    | length args /= 1 = liftIO $ putStrLn usage
    | otherwise = do
        dbInit $ head args
        dbGenExtAddr "default" $ optCount opts
        liftIO $ putStrLn "Wallet initialized" 

cmdListAddr :: Options -> Args -> CmdAction
cmdListAddr opts args 
    | length args > 1 = liftIO $ putStrLn usage
    | otherwise = do
        let acc = if null args then "default" else head args
        addr <- dbExtAddr acc $ optCount opts
        liftIO $ do
            putStrLn $ "Account: " ++ acc
            forM_ addr formatAddr

cmdGenAddr :: Options -> Args -> CmdAction
cmdGenAddr opts args 
    | length args > 1 = liftIO $ putStrLn usage
    | otherwise = do
        let acc = if null args then "default" else head args
        addr <- dbGenExtAddr acc $ optCount opts
        liftIO $ do
            putStrLn $ "Account: " ++ acc
            forM_ addr formatAddr

formatAddr :: WAddr -> IO ()
formatAddr (WAddr a l i _)
    | null l    = putStrLn def
    | otherwise = putStrLn $ def ++ lab
    where def = (show i) ++ ") " ++ a
          lab = " (" ++ l ++ ")"

cmdDumpKey :: Args -> CmdAction
cmdDumpKey args 
    | length args > 1 = liftIO $ putStrLn usage
    | otherwise = do
        let acc = if null args then "default" else head args
        dbGetAcc acc >>= \accM -> case accM of
            Nothing  -> error $ "Account " ++ (head args) ++ " does not exist"
            Just acc -> liftIO $ do
                putStrLn $ "Account: " ++ (accName acc)
                putStrLn $ xPubExport $ runAccPubKey $ accKey acc

cmdDecodeTx :: Options -> Args -> CmdAction
cmdDecodeTx opts args
    | null args = liftIO $ putStrLn usage
    | isNothing bs = error "<tx>: Invalid HEX encoding"
    | otherwise = case eitherTx of
        Left err -> error err
        Right tx -> liftIO $ pp tx
    where bs       = hexToBS $ head args
          eitherTx = decodeToEither $ fromJust bs :: Either String Tx

cmdBuildTx :: Options -> Args -> CmdAction
cmdBuildTx opts args
    | length args /= 2 = liftIO $ putStrLn usage
    | otherwise = case buildAddrTx (map f os) as of
        Right tx -> liftIO $ putStrLn $ bsToHex $ encode' tx
        Left err -> error err
    where os = read (args !! 0) :: [(String,Word32)]
          as = read (args !! 1) :: [(String,Word64)]
          f (s,i) = OutPoint (decode' $ BS.reverse $ fromJust $ hexToBS s) i

--cmdSignTx :: Options -> Args -> CmdAction
--cmdSignTx m opts args
--    | length args < 3 || length args > 4 = error usage
--    | isNothing bs = error "<tx>: Invalid HEX encoding"
--    | otherwise = case eitherTx of
--        Left err -> error err
--        Right tx -> lift $ putStrLn $ show $
--            liftM (bsToHex . encode') (detSignTx tx (map (g . f) os) $ map h is)
--    where ai  = fromIntegral $ optAccount opts
--          acc = fromMaybe (error $ "Invalid account index") $ accPrvKey m ai
--          bs = hexToBS $ args !! 0
--          eitherTx = decodeToEither $ fromJust bs :: Either String Tx
--          os = read (args !! 1) :: [(String,Word32,String)]
--          is = read (args !! 2) :: [Word32]
--          keys = map (fromJust . xPubImport) $ drop 3 args
--          f (t,i,s) = ( (Script $ runGet' getScriptOps $ fromJust $ hexToBS s) 
--                      , ( OutPoint 
--                            (decode' $ BS.reverse $ fromJust $ hexToBS t) 
--                            i
--                        )
--                      )
--          g (s,o) | null keys = SigInput s o $ optSigHash opts
--                  | otherwise = SigInputSH s o rdm $ optSigHash opts
--                  where rdm = encodeOutput $
--                              PayMulSig (map xPubKey keys) (optRequire opts)
--          h i = xPrvKey $ runAddrPrvKey $ fromJust $ 
--                    if (optInternal opts) then intPrvKey acc i
--                                          else extPrvKey acc i
        


{-# LANGUAGE CPP #-}
module System.Process.Windows
    ( mkProcessHandle
    , translateInternal
    , createProcess_Internal
    , withCEnvironment
    , closePHANDLE
    , startDelegateControlC
    , endDelegateControlC
    , stopDelegateControlC
    , isDefaultSignal
    , createPipeInternal
    , interruptProcessGroupOfInternal
    ) where

import System.Process.Common
import Control.Concurrent
import Control.Exception
import Data.Bits
import Foreign.C
import Foreign.Marshal
import Foreign.Ptr
import Foreign.Storable
import System.IO.Unsafe

import System.Posix.Internals
import GHC.IO.Exception
import GHC.IO.Handle.FD
import GHC.IO.Handle.Types hiding (ClosedHandle)
import System.IO.Error
import GHC.IO.IOMode

import System.Directory         ( doesFileExist )
import System.Environment       ( getEnv )
import System.FilePath
import System.Win32.Console (generateConsoleCtrlEvent, cTRL_BREAK_EVENT)
import System.Win32.Process (getProcessId)

-- The double hash is used so that hsc does not process this include file
##include "processFlags.h"

#include <fcntl.h>     /* for _O_BINARY */

throwErrnoIfBadPHandle :: String -> IO PHANDLE -> IO PHANDLE
throwErrnoIfBadPHandle = throwErrnoIfNull

-- On Windows, we have to close this HANDLE when it is no longer required,
-- hence we add a finalizer to it
mkProcessHandle :: PHANDLE -> IO ProcessHandle
mkProcessHandle h = do
   m <- newMVar (OpenHandle h)
   _ <- mkWeakMVar m (processHandleFinaliser m)
   return (ProcessHandle m False)

processHandleFinaliser :: MVar ProcessHandle__ -> IO ()
processHandleFinaliser m =
   modifyMVar_ m $ \p_ -> do
        case p_ of
          OpenHandle ph -> closePHANDLE ph
          _ -> return ()
        return (error "closed process handle")

closePHANDLE :: PHANDLE -> IO ()
closePHANDLE ph = c_CloseHandle ph

foreign import
#if defined(i386_HOST_ARCH)
  stdcall
#elif defined(x86_64_HOST_ARCH)
  ccall
#else
#error "Unknown architecture"
#endif
  unsafe "CloseHandle"
  c_CloseHandle
        :: PHANDLE
        -> IO ()

createProcess_Internal
  :: String                     -- ^ function name (for error messages)
  -> CreateProcess
  -> IO (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)

createProcess_Internal fun CreateProcess{ cmdspec = cmdsp,
                                  cwd = mb_cwd,
                                  env = mb_env,
                                  std_in = mb_stdin,
                                  std_out = mb_stdout,
                                  std_err = mb_stderr,
                                  close_fds = mb_close_fds,
                                  create_group = mb_create_group,
                                  delegate_ctlc = _ignored,
                                  detach_console = mb_detach_console,
                                  create_new_console = mb_create_new_console,
                                  new_session = mb_new_session }
 = do
  (cmd, cmdline) <- commandToProcess cmdsp
  withFilePathException cmd $
   alloca $ \ pfdStdInput  ->
   alloca $ \ pfdStdOutput ->
   alloca $ \ pfdStdError  ->
   maybeWith withCEnvironment mb_env $ \pEnv ->
   maybeWith withCWString mb_cwd $ \pWorkDir -> do
   withCWString cmdline $ \pcmdline -> do

     fdin  <- mbFd fun fd_stdin  mb_stdin
     fdout <- mbFd fun fd_stdout mb_stdout
     fderr <- mbFd fun fd_stderr mb_stderr

     -- #2650: we must ensure mutual exclusion of c_runInteractiveProcess,
     -- because otherwise there is a race condition whereby one thread
     -- has created some pipes, and another thread spawns a process which
     -- accidentally inherits some of the pipe handles that the first
     -- thread has created.
     --
     -- An MVar in Haskell is the best way to do this, because there
     -- is no way to do one-time thread-safe initialisation of a mutex
     -- the C code.  Also the MVar will be cheaper when not running
     -- the threaded RTS.
     proc_handle <- withMVar runInteractiveProcess_lock $ \_ ->
                    throwErrnoIfBadPHandle fun $
                         c_runInteractiveProcess pcmdline pWorkDir pEnv
                                fdin fdout fderr
                                pfdStdInput pfdStdOutput pfdStdError
                                ((if mb_close_fds then RUN_PROCESS_IN_CLOSE_FDS else 0)
                                .|.(if mb_create_group then RUN_PROCESS_IN_NEW_GROUP else 0)
                                .|.(if mb_detach_console then RUN_PROCESS_DETACHED else 0)
                                .|.(if mb_create_new_console then RUN_PROCESS_NEW_CONSOLE else 0)
                                .|.(if mb_new_session then RUN_PROCESS_NEW_SESSION else 0))

     hndStdInput  <- mbPipe mb_stdin  pfdStdInput  WriteMode
     hndStdOutput <- mbPipe mb_stdout pfdStdOutput ReadMode
     hndStdError  <- mbPipe mb_stderr pfdStdError  ReadMode

     ph <- mkProcessHandle proc_handle
     return (hndStdInput, hndStdOutput, hndStdError, ph)

{-# NOINLINE runInteractiveProcess_lock #-}
runInteractiveProcess_lock :: MVar ()
runInteractiveProcess_lock = unsafePerformIO $ newMVar ()

-- The following functions are always present in the export list. For
-- compatibility with the non-Windows code, we provide the same functions with
-- matching type signatures, but implemented as no-ops. For details, see:
-- <https://github.com/haskell/process/pull/21>
startDelegateControlC :: IO ()
startDelegateControlC = return ()

endDelegateControlC :: ExitCode -> IO ()
endDelegateControlC _ = return ()

stopDelegateControlC :: IO ()
stopDelegateControlC = return ()

-- End no-op functions

foreign import ccall unsafe "runInteractiveProcess"
  c_runInteractiveProcess
        :: CWString
        -> CWString
        -> Ptr CWString
        -> FD
        -> FD
        -> FD
        -> Ptr FD
        -> Ptr FD
        -> Ptr FD
        -> CInt                         -- flags
        -> IO PHANDLE

commandToProcess
  :: CmdSpec
  -> IO (FilePath, String)
commandToProcess (ShellCommand string) = do
  cmd <- findCommandInterpreter
  return (cmd, translateInternal cmd ++ " /c " ++ string)
        -- We don't want to put the cmd into a single
        -- argument, because cmd.exe will not try to split it up.  Instead,
        -- we just tack the command on the end of the cmd.exe command line,
        -- which partly works.  There seem to be some quoting issues, but
        -- I don't have the energy to find+fix them right now (ToDo). --SDM
        -- (later) Now I don't know what the above comment means.  sigh.
commandToProcess (RawCommand cmd args) = do
  return (cmd, translateInternal cmd ++ concatMap ((' ':) . translateInternal) args)

-- Find CMD.EXE (or COMMAND.COM on Win98).  We use the same algorithm as
-- system() in the VC++ CRT (Vc7/crt/src/system.c in a VC++ installation).
findCommandInterpreter :: IO FilePath
findCommandInterpreter = do
  -- try COMSPEC first
  catchJust (\e -> if isDoesNotExistError e then Just e else Nothing)
            (getEnv "COMSPEC") $ \_ -> do

    -- try to find CMD.EXE or COMMAND.COM
    {-
    XXX We used to look at _osver (using cbits) and pick which shell to
    use with
    let filename | osver .&. 0x8000 /= 0 = "command.com"
                 | otherwise             = "cmd.exe"
    We ought to use GetVersionEx instead, but for now we just look for
    either filename
    -}
    path <- getEnv "PATH"
    let
        -- use our own version of System.Directory.findExecutable, because
        -- that assumes the .exe suffix.
        search :: [FilePath] -> IO (Maybe FilePath)
        search [] = return Nothing
        search (d:ds) = do
                let path1 = d </> "cmd.exe"
                    path2 = d </> "command.com"
                b1 <- doesFileExist path1
                b2 <- doesFileExist path2
                if b1 then return (Just path1)
                      else if b2 then return (Just path2)
                                 else search ds
    --
    mb_path <- search (splitSearchPath path)

    case mb_path of
      Nothing -> ioError (mkIOError doesNotExistErrorType
                                "findCommandInterpreter" Nothing Nothing)
      Just cmd -> return cmd

translateInternal :: String -> String
translateInternal xs = '"' : snd (foldr escape (True,"\"") xs)
  where escape '"'  (_,     str) = (True,  '\\' : '"'  : str)
        escape '\\' (True,  str) = (True,  '\\' : '\\' : str)
        escape '\\' (False, str) = (False, '\\' : str)
        escape c    (_,     str) = (False, c : str)
        -- See long comment above for what this function is trying to do.
        --
        -- The Bool passed back along the string is True iff the
        -- rest of the string is a sequence of backslashes followed by
        -- a double quote.

withCEnvironment :: [(String,String)] -> (Ptr CWString -> IO a) -> IO a
withCEnvironment envir act =
  let env' = foldr (\(name, val) env0 -> name ++ ('=':val)++'\0':env0) "\0" envir
  in withCWString env' (act . castPtr)

isDefaultSignal :: CLong -> Bool
isDefaultSignal = const False

createPipeInternal :: IO (Handle, Handle)
createPipeInternal = do
    (readfd, writefd) <- allocaArray 2 $ \ pfds -> do
        throwErrnoIfMinus1_ "_pipe" $ c__pipe pfds 2 (#const _O_BINARY)
        readfd <- peek pfds
        writefd <- peekElemOff pfds 1
        return (readfd, writefd)
    (do readh <- fdToHandle readfd
        writeh <- fdToHandle writefd
        return (readh, writeh)) `onException` (close' readfd >> close' writefd)

close' :: CInt -> IO ()
close' = throwErrnoIfMinus1_ "_close" . c__close

foreign import ccall "io.h _pipe" c__pipe ::
    Ptr CInt -> CUInt -> CInt -> IO CInt

foreign import ccall "io.h _close" c__close ::
    CInt -> IO CInt

interruptProcessGroupOfInternal
    :: ProcessHandle    -- ^ A process in the process group
    -> IO ()
interruptProcessGroupOfInternal ph = do
    withProcessHandle ph $ \p_ -> do
        case p_ of
            ClosedHandle _ -> return ()
            OpenHandle h -> do
#if mingw32_HOST_OS
                pid <- getProcessId h
                generateConsoleCtrlEvent cTRL_BREAK_EVENT pid
-- We can't use an #elif here, because MIN_VERSION_unix isn't defined
-- on Windows, so on Windows cpp fails:
-- error: missing binary operator before token "("
#else
                pgid <- getProcessGroupIDOf h
                signalProcessGroup sigINT pgid
#endif
                return ()

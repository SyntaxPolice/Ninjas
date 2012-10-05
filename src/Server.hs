{-# LANGUAGE RecordWildCards #-}
module Server (serverMain) where

import Control.Concurrent
import Control.Monad
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Graphics.Gloss.Data.Point
import Graphics.Gloss.Geometry.Line
import Network
import System.IO

import Simulation
import NetworkMessages
import ListUtils

npcCount :: Int
npcCount = 10

serverMain :: Int -> IO ()
serverMain n = do
  sock <- listenOn gamePort
  _ <- forkIO $ do
    (hs, names) <- getConnections sock n
    sClose sock
    w   <- initServerWorld n names
    var <- newMVar w
    let setCommand = generateSetWorld w
    announce hs setCommand
    -- these handles are only to be used for reading
    rawHs <- unsafeReadHandles hs
    forM_ rawHs $ \(i,h) ->
       forkIO $ clientSocketLoop i hs h var

    readyCountdown hs var

    runServer hs var
  _ <- getLine
  return ()

readyCountdown :: Handles -> MVar ServerWorld -> IO ()
readyCountdown hs var =
  do forM_ [3,2,1::Int] $ \i ->
       do announce hs $ ServerMessage $ show i
          threadDelay 1000000
     announce hs ServerReady
     modifyMVar_ var $ \w -> return w { serverActive = True }

generateSetWorld :: ServerWorld -> ServerCommand
generateSetWorld w = SetWorld [(npcPos npc, npcFacing npc) | npc <- allNpcs w]

allNpcs :: ServerWorld -> [NPC]
allNpcs w = map playerNpc (serverPlayers w) ++ serverNpcs w

isStuckPlayer :: Player -> Bool
isStuckPlayer p =
  case npcState (playerNpc p) of
    Dead          -> True
    Attacking {}  -> True
    _             -> False

clientSocketLoop :: Int -> Handles -> Handle -> MVar ServerWorld -> IO ()
clientSocketLoop i hs h var = forever $
  do msg  <- hGetClientCommand h
     (msgs,kills) <- modifyMVar var $ \w -> return $
       let players = serverPlayers w
           (me,them) = extract i players
           mapPlayer f = w { serverPlayers = updateList i f (serverPlayers w) }

       in case msg of
            _        | not (serverActive w) || isStuckPlayer me -> (w,([],[]))
            ClientSmoke
              | playerSmokes me <= 0 -> (w,([],[]))
              | otherwise ->
                   (mapPlayer $ \p -> p { playerSmokes = playerSmokes p - 1 }
                   , ([ServerSmoke (npcPos (playerNpc me))], [])
                   )
            ClientCommand cmd -> case cmd of
              Move _ pos0 ->
                -- Disregard where the player says he is moving from
                let pos = constrainPoint (npcPos (playerNpc me)) pos0
                in if pointInBox pos boardMin boardMax
                   then   ( mapPlayer $ mapPlayerNpc $ \npc -> walkingNPC npc pos
                          , ([ServerCommand i (Move (npcPos (playerNpc me)) pos)], [])
                          )
                   else   (w, ([],[]))
              Stop     -> ( mapPlayer $ mapPlayerNpc $ \npc -> waitingNPC npc Nothing False
                          , ([ServerCommand i cmd], [])
                          )
              Attack   -> let (me', them', npcs', cmds, kills) = performAttack me them (serverNpcs w)
                          in  (w { serverPlayers = insertPlayer me' them'
                                 , serverNpcs    = npcs'
                                 }
                              , (cmds, kills)
                              )
              _        -> (w,([],[]))
            _ -> (w,([],[]))
     forM_ msgs $ \out -> announce hs out
     forM_ kills $ \(killed,killer) ->
       announceOne hs killed (ServerMessage ("Killed by " ++ killer))

getConnections :: Socket -> Int -> IO (Handles,[String])
getConnections s n =
  do var <- newMVar []
     aux (Handles var) [] n
  where
  aux hs names 0 = return (hs, names)
  aux hs names i =
    do announce hs $ ServerWaiting i
       (h,host,port) <- accept s
       hSetBuffering h LineBuffering
       ClientJoin name <- hGetClientCommand h
       putStrLn $ "Got connection from " ++ name ++ "@" ++ host ++ ":" ++ show port
       let i' = i - 1
       addHandle i' h hs
       aux hs (name:names) i'

runServer :: Handles -> MVar ServerWorld -> IO a
runServer hs w = loop =<< getCurrentTime
  where
  loop lastTime =
    do thisTime <- getCurrentTime
       let elapsed :: Float
           elapsed = realToFrac $ diffUTCTime thisTime lastTime
       modifyMVar_ w $ updateServerWorld hs elapsed
       threadDelay $ truncate $ 1000000 / fromIntegral eventsPerSecond - elapsed
       loop thisTime

initServerWorld :: Int -> [String] -> IO ServerWorld
initServerWorld playerCount names =
  do serverPlayers <- zipWithM initPlayer [0 ..] names
     serverNpcs    <- mapM (initServerNPC True) [playerCount .. npcCount + playerCount - 1]
     let serverActive = False
     return ServerWorld { .. }

updateServerWorld    :: Handles -> Float -> ServerWorld -> IO ServerWorld
updateServerWorld hs t w
  | not (serverActive w) = return w
  | otherwise =
     do pcs'  <- mapM (updatePlayer hs t) $ serverPlayers w

        let survivors = filter (not . (Dead ==) . npcState . playerNpc) pcs'
            winners = case survivors of
              [_] -> survivors
              _   -> filter isWinner pcs'

        unless (null winners)
           $ announce hs $ ServerMessage
           $ intercalate ", " (map playerUsername winners) ++ " wins!"

        npcs' <- mapM (updateNPC hs t True) $ serverNpcs    w
        return w { serverPlayers = pcs'
                 , serverNpcs    = npcs'
                 , serverActive  = null winners
                 }

updatePlayer :: Handles -> Float -> Player -> IO Player
updatePlayer hs t p =
  do npc' <- updateNPC hs t False $ playerNpc p
     let p' = p { playerNpc = npc' }
     case whichPillar (npcPos npc') of
       Just i | i `notElem` playerVisited p -> 
         do announce hs ServerDing
            return p' { playerVisited = i : playerVisited p' }
       _ -> return p'

isWinner :: Player -> Bool
isWinner p = length (playerVisited p) == length pillars

updateNPC :: Handles -> Float -> Bool -> NPC -> IO NPC
updateNPC hs t think npc =
  do let (npc',mbTask) = updateNPC' t npc

     case guard think >> mbTask of

       Just ChooseWait ->
         do time <- pickWaitTime True
            return $ waitingNPC npc' time False

       Just ChooseDestination ->
         do tgt <- randomBoardPoint
            announce hs $ ServerCommand (npcName npc') (Move (npcPos npc) tgt)
            return $ walkingNPC npc' tgt

       Nothing -> return npc'

constrainPoint :: Point -> Point -> Point
constrainPoint from
  = aux intersectSegVertLine (fst boardMin)
  . aux intersectSegVertLine (fst boardMax)
  . aux intersectSegHorzLine (snd boardMin)
  . aux intersectSegHorzLine (snd boardMax)
  where
  aux f x p = fromMaybe p (f from p x)

newtype Handles = Handles (MVar [(Int,Handle)])

addHandle :: Int -> Handle -> Handles -> IO ()
addHandle i h (Handles var) = modifyMVar_ var $ \hs -> return ((i,h):hs)

unsafeReadHandles :: Handles -> IO [(Int,Handle)]
unsafeReadHandles (Handles var) = readMVar var

announceOne :: Handles -> Int -> ServerCommand -> IO ()
announceOne (Handles var) i msg = withMVar var $ \hs ->
  case lookup i hs of
    Just h  -> hPutServerCommand h msg
    Nothing -> return ()    -- XXX: Perhaps say something here.

announce :: Handles -> ServerCommand -> IO ()
announce (Handles var) msg = withMVar var $ \hs ->
  mapM_ (`hPutServerCommand` msg) (map snd hs)


module Openspace.Ui.Stream where

import Control.Monad.Eff
import Control.Monad.Eff.Console
import Control.Monad.ST
import DOM
import Data.Either
import Data.Foreign
import Openspace.Engine
import Openspace.Network.Socket
import Openspace.Types
import Openspace.Ui.Emitter
import Openspace.Ui.Parser
import Openspace.Ui.Render
import Prelude
import Rx.Observable

foreign import setDrag :: forall eff. Eff eff Unit
foreign import unsetDrag :: forall eff. Eff eff Unit

netStream :: forall eff. Socket -> Eff( net :: Net | eff ) (Observable Action)
netStream socket = do
  onReceive <- socketObserver socket
  return $ actionFromForeign parseAction id <$> (parseMessage <$> onReceive)

dragStream :: forall eff. Eff( dom :: DOM| eff) (Observable Action)
dragStream = do
  lookup <- emitterLookup <$> getEmitters
  let dragOverSlot = (\e -> case parseSlot (getDetail e) of
                         Right s -> AssignTopic s
                         Left err -> UnassignTopic
                     ) <$> lookup "dragOverSlot"

      dragOverTrash = const DeleteTopic <$> lookup "dragOverTrash"

      -- HTML 5 fires dragLeave before dragEnd occurs
      -- TODO: Find a cleaner solution
      dragLeave = delay 30 $ const UnassignTopic
                  <$> lookup "dragLeaveSlot" `merge` lookup "dragLeaveTrash"

      dragOver = dragLeave `merge` dragOverSlot `merge` dragOverTrash

      dragStart = parseTopic <<< getDetail
                  <$> lookup "dragStartTopic" `merge` lookup "dragStartGridTopic"
      dragEnd = lookup "dragEndTopic" `merge` lookup "dragEndGridTopic"

      {- rebindable "bind" does make this a lot easier -}
      dragTopic :: Observable Action
      dragTopic = do
        let bind = flatMapLatest
        t' <- dragStart
        case t' of
          Right t -> do
            action <- dragOver
            dragEnd
            return (action t)
          Left e -> return $ ShowError (show e)

  runObservable $ const setDrag <$> dragStart
  runObservable $ const unsetDrag <$> dragEnd

  return dragTopic

uiStream :: forall eff. Eff( dom :: DOM | eff ) (Observable Action)
uiStream = do
  lookup <- emitterLookup <$> getEmitters
  let addTopic    = (actionFromForeign parseTopic AddTopic) <<< getDetail
                    <$> lookup "addTopic"
      addRoom     = (actionFromForeign parseRoom AddRoom) <<< getDetail
                    <$> lookup "addRoom"
      deleteRoom  = (actionFromForeign parseRoom DeleteRoom) <<< getDetail
                    <$> lookup "deleteRoom"
      addBlock    = (actionFromForeign parseBlock AddBlock) <<< getDetail
                    <$> lookup "addBlock"
      deleteBlock = (actionFromForeign parseBlock DeleteBlock) <<< getDetail
                    <$> lookup "deleteBlock"
      changeGrid = addRoom `merge` deleteRoom `merge` addBlock `merge` deleteBlock
  dragTopic <- dragStream
  return $ addTopic `merge` dragTopic `merge` changeGrid

main = do
  socketUrl <- getSocketUrl
  -- Uncomment for testing:
  -- let sockEmitter = getSocket ("ws://frost.kritzcreek.me/socket/0")
  -- Comment for testing:
  let sockEmitter = getSocket ("ws://" ++ socketUrl)


  -- Initial State
  appSt <- newSTRef emptyState
  -- Initial Render
  renderMenu (show <$> topicTypes)
  readSTRef appSt >>= renderApp

  --Request Initial State
  emitRefresh sockEmitter

  -- Observable Action
  ui  <- uiStream
  net <- netStream sockEmitter
  -- Broadcast the UI Observable
  subscribe ui (\a -> case a of
                   ShowError e -> log e
                   _ -> emitAction sockEmitter (serialize a))
  -- Evaluate Actions from the Server
  subscribe net (\a -> modifySTRef appSt (evalAction a) >>= renderApp)

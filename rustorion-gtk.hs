{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, DuplicateRecordFields, RecordWildCards #-}

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Data.Default
import Data.Function ((&))
import Data.IORef
import qualified Data.Map as M
import Data.Map ((!))
import Data.Maybe
import Graphics.Rendering.Cairo
import Graphics.UI.Gtk as GTK
import SDL.Init
import SDL.Mixer
import System.Directory
import System.Exit

import CertGen
import RPC
import Types

toColor :: Types.Color -> GTK.Color
toColor (Types.Color r g b) = GTK.Color (round $ r * 65535) (round $ g * 65535) (round $ b * 65535)

makeScrollable scroll = do
	hadj <- scrolledWindowGetHAdjustment scroll
	vadj <- scrolledWindowGetVAdjustment scroll
	mousePressCoords <- newIORef (0, 0)

	on scroll motionNotifyEvent $ tryEvent $ do
		[Button3] <- eventModifierMouse	-- FIXME figure out why it receives all the events regardless of widgetGetEvents output
		(x, y) <- eventCoordinates
		(diffx, diffy) <- liftIO $ readIORef mousePressCoords
		liftIO $ adjustmentSetValue hadj $ diffx - x
		liftIO $ adjustmentSetValue vadj $ diffy - y
		eventRequestMotions

	on scroll buttonPressEvent $ tryEvent $ do
		RightButton <- eventButton
		adjx <- liftIO $ adjustmentGetValue hadj
		adjy <- liftIO $ adjustmentGetValue vadj
		(mx, my) <- eventCoordinates
		liftIO $ writeIORef mousePressCoords (adjx + mx, adjy + my)

scaleFactor = 20
scaleCoord x = 100 + (round $ x / scaleFactor)

addShip :: TVar UIState -> Fixed -> UniverseView -> (Ship -> IO ()) -> Ship -> IO ()
addShip uiState layout view onClick ship@Ship { name = name, uuid = shid } = do
	UIState {..} <- readTVarIO uiState
	butt <- buttonNewWithLabel $ name
	set butt [ widgetOpacity := 0.7 ]
	shipImage <- imageNewFromIconName ("ship" :: String) IconSizeButton
	buttonSetImage butt shipImage
	on butt buttonActivated $ onClick ship
	let ssid = (to $ ships_in_star_systems view) ! shid
	let (UniverseLocation x y) = location $ (star_systems view) ! ssid
	let shipButtonYOffset = 25
	fixedPut layout butt ((scaleCoord $ x - fst galaxyDisplayOffsets), (shipButtonYOffset + (scaleCoord $ y - snd galaxyDisplayOffsets)))

makeStarSystemWidget :: Types.Color -> IO DrawingArea
makeStarSystemWidget Types.Color {..} = do
	widget <- drawingAreaNew
	it <- iconThemeGetDefault
	-- TODO gtk_icon_theme_lookup_by_gicon_for_scale
	let size = 48
	(Just starPix) <- iconThemeLoadIcon it ("star" :: String) size IconLookupGenericFallback
	(Just reticlePix) <- iconThemeLoadIcon it ("reticle" :: String) size IconLookupGenericFallback
	widgetSetSizeRequest widget size size
	on widget draw $ do
		-- set the star system border color to the empire color and make it transparent
		setSourceRGB (realToFrac r) (realToFrac g) (realToFrac b)
		let lineWidth = 4
		setLineWidth lineWidth
		arc ((fromIntegral size) / 2) ((fromIntegral size) / 2) ((fromIntegral size) / 2 - lineWidth / 2) 0 (2 * pi)
		stroke
		setSourcePixbuf starPix 0 0
		paint
		setSourcePixbuf reticlePix 0 0
		paint
	pure widget

addStarSystem :: Fixed -> (StarSystem -> IO ()) -> (Double, Double) -> (Empire, StarSystem) -> IO ()
addStarSystem layout onClick (xoff, yoff) (empire, ss@StarSystem {..}) = do
	butt <- makeStarSystemWidget $ color empire
	set butt [ widgetOpacity := 0.9 ]

	-- TODO draw the system name and crown on the galaxy map
	--mapM (\cap -> when (cap == uuid) $ do
	--		capitalImage <- imageNewFromIconName ("crown" :: String) IconSizeButton
	--		buttonSetImage butt capitalImage
	--	) $ maybeToList $ capital empire

	on butt buttonPressEvent $ tryEvent $ do
		LeftButton <- eventButton
		liftIO $ onClick ss
	let (UniverseLocation x y) = location
	-- place the buttons in the layout so they can be realized
	fixedPut layout butt ((scaleCoord $ x - xoff), (scaleCoord $ y - yoff))
	after butt realize $ do
		-- center the star system buttons on their locations
		(Rectangle x y w h) <- widgetGetAllocation butt
		fixedMove layout butt (x - (w `div` 2), y - (h `div` 2))
	pure ()

addStarSystems uiState layout onClick systems = do
	let offsets = (minimum $ map (ulx . location . snd) systems, minimum $ map (uly . location . snd) systems)
	atomically $ modifyTVar uiState $ \s -> s { galaxyDisplayOffsets = offsets }
	mapM_ (addStarSystem layout onClick offsets) systems

drawLane (xoff, yoff) (UniverseLocation x1 y1) (UniverseLocation x2 y2) = do
	setLineWidth 2
	setSourceRGB 0 1 0
	moveTo (fromIntegral $ scaleCoord $ x1 - xoff) (fromIntegral $ scaleCoord $ y1 - yoff)
	lineTo (fromIntegral $ scaleCoord $ x2 - xoff) (fromIntegral $ scaleCoord $ y2 - yoff)
	stroke

drawLanes offsets UniverseView {..} = do
	-- black interstellar space
	setSourceRGB 0 0 0
	paint

	mapM_ (\(id1, ids) -> mapM_ (\id2 ->
				drawLane offsets (location $ star_systems ! id1) (location $ star_systems ! id2)
			) ids
		) $ M.toList starlanes

annotateStarSystems UniverseView {..} = M.fromList $ map (\(id, ss) ->
		let empire = empires ! ((to star_systems_in_empires) ! id) in
		(id, (empire, ss))
	) $ M.toList $ star_systems

turnWaiter host key cert = do
	-- first we get the current turn data and utilize it
	let port = 4433
	conn <- rpcConnect host port key cert
	windowRef <- newIORef =<< postGUISync windowNew
	handleNewTurn conn windowRef

	-- then we're waiting for the next turns and handle them
	let backconnect_port = 4434
	backconn <- rpcConnect host backconnect_port key cert
	forever $ do
		rpcHandle backconn
		-- assume it's a turn change
		forkIO $ load "resources/newturn.ogg" >>= play
		handleNewTurn conn windowRef

makeWindow = do
	w <- windowNew
	set w [windowTitle := ("rustorion-gtk" :: String)]

	-- or better https://askubuntu.com/questions/153549/how-to-detect-a-computers-physical-screen-size-in-gtk
	scr <- fmap fromJust screenGetDefault
	x <- screenGetWidth scr
	y <- screenGetHeight scr
	windowSetDefaultSize w x y
	windowFullscreen w
	on w deleteEvent $ liftIO $ exitWith ExitSuccess
	pure w

handleNewTurn conn windowRef = do
	view <- getView conn
	print view
	uiState <- newTVarIO def
	postGUISync $ do
		-- purge the old window
		readIORef windowRef >>= widgetDestroy
		w <- makeWindow
		writeIORef windowRef w

		topPaned <- vPanedNew
		containerAdd w topPaned

		topPanel <- hBoxNew False 0
		panedPack1 topPaned topPanel False False

		turnLabel <- labelNew $ Just ("Turn " ++ (show $ turn_number view))
		boxPackStart topPanel turnLabel PackNatural 0

		readyButton <- checkButtonNew
		readyButtonLabel <- labelNew $ Just ("Ready" :: String)
		containerAdd readyButton readyButtonLabel
		boxPackStart topPanel readyButton PackNatural 0
		on readyButton buttonActivated $ do
			gotReady <- toggleButtonGetActive readyButton
			readyToAct <- widgetGetSensitive readyButton
			when (gotReady && readyToAct) $ do
				readyButton & widgetSetSensitive $ False
				labelSetText readyButtonLabel ("sending..." :: String)
				readyButton & toggleButtonSetActive $ False
				toggleButtonSetInconsistent readyButton True
				setActions conn []
				-- after successful action submission
				toggleButtonSetInconsistent readyButton False
				labelSetText readyButtonLabel ("Ready" :: String)
				readyButton & toggleButtonSetActive $ True
				readyButton & widgetSetSensitive $ True

		panels <- vPanedNew
		panedPack2 topPaned panels True True

		infoLabel <- labelNew (Nothing :: Maybe String)
		labelSetLineWrap infoLabel True
		panedPack2 panels infoLabel False False

		universeScroll <- scrolledWindowNew Nothing Nothing
		scrolledWindowSetPolicy universeScroll PolicyAutomatic PolicyAutomatic
		makeScrollable universeScroll
		panedPack1 panels universeScroll True True

		-- put interactive items over the galaxy map background
		overlay <- overlayNew
		scrolledWindowAddWithViewport universeScroll overlay

		starlaneLayer <- drawingAreaNew
		containerAdd overlay starlaneLayer

		layout <- fixedNew
		overlayAdd overlay layout	-- put it over the starlane map

		-- make overlay respect the size of the layout
		sg <- sizeGroupNew SizeGroupBoth
		sizeGroupAddWidget sg starlaneLayer
		sizeGroupAddWidget sg layout

		-- cache the information about star system ownership
		let annotatedStarSystems = annotateStarSystems view

		-- draw our view content
		addStarSystems uiState layout (labelSetText infoLabel . show) $ M.elems $ annotatedStarSystems
		mapM_ (addShip uiState layout view (labelSetText infoLabel . show)) $ M.elems $ ships view
		UIState { galaxyDisplayOffsets = offsets } <- readTVarIO uiState
		on starlaneLayer draw $ drawLanes offsets view

		widgetShowAll w

main = do
	-- getArgs
	[key, cert] <- unsafeInitGUIForThreadedRTS
	missingAuthData <- fmap (not . and) $ sequence $ map doesFileExist [key, cert]
	when missingAuthData $ makeKeyCert key cert

	SDL.Init.initialize [InitAudio]
	-- 22050Hz by default, seriously!?
	let audio = def { audioFrequency = max 44100 $ audioFrequency def }
	openAudio audio 16384

	-- request a dark theme variant
	sets <- fmap fromJust $ settingsGetDefault
	settingsSetLongProperty sets ("gtk-application-prefer-dark-theme" :: String) 1 []
	-- permit putting images on buttons
	settingsSetLongProperty sets ("gtk-button-images" :: String) 1 []

	-- tell gtk where to look for icons
	iconTheme <- iconThemeGetDefault
	iconThemePrependSearchPath iconTheme "resources"

	let host = "localhost"
	forkIO $ turnWaiter host key cert
	mainGUI

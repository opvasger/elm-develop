module DevTools.Browser.Main exposing
    ( Configuration
    , Program
    , toDocument
    , toHtml
    , toInit
    , toMsg
    , toSubscriptions
    , toUpdate
    )

import Browser
import Browser.Dom
import Browser.Events
import DevTools.Browser.Elements as Elements
import Element
import File exposing (File)
import File.Download
import File.Select
import History exposing (History)
import Html exposing (Html)
import Json.Decode as Jd
import Json.Encode as Je
import Task exposing (Task)
import Time


type alias Program flags model msg =
    Platform.Program flags (Model model msg) (Msg model msg)


type alias Configuration flags model msg =
    { printModel : model -> String
    , encodeMsg : msg -> Je.Value
    , msgDecoder : Jd.Decoder msg
    , toSession : flags -> Maybe String
    , output : Je.Value -> Cmd (Msg model msg)
    }



-- MouseEvent


type MouseEvent
    = NoEvent
    | Drag Int Int Int Int
    | Hover Elements.HoverTarget


toHoverTarget : MouseEvent -> Elements.HoverTarget
toHoverTarget event =
    case event of
        Hover target ->
            target

        _ ->
            Elements.noTarget



-- Model


type alias Model model msg =
    { history : History model msg
    , debuggerWidth : Int
    , debuggerBodyHeight : Int
    , debuggerLeftPosition : Int
    , debuggerTopPosition : Int
    , viewportHeight : Int
    , viewportWidth : Int
    , isModelOverlayed : Bool
    , loadModelError : Maybe Jd.Error
    , mouseEvent : MouseEvent
    }


encodeModel : (msg -> Je.Value) -> Model model msg -> Je.Value
encodeModel encodeMsg model =
    Je.object
        [ ( "history", History.encode encodeMsg model.history )
        , ( "debuggerWidth", Je.int model.debuggerWidth )
        , ( "debuggerBodyHeight", Je.int model.debuggerBodyHeight )
        , ( "debuggerLeftPosition", Je.int model.debuggerLeftPosition )
        , ( "debuggerTopPosition", Je.int model.debuggerTopPosition )
        , ( "viewportHeight", Je.int model.viewportHeight )
        , ( "viewportWidth", Je.int model.viewportWidth )
        , ( "isModelOverlayed", Je.bool model.isModelOverlayed )
        ]


modelDecoder :
    (msg -> model -> ( model, Cmd msg ))
    -> Jd.Decoder msg
    -> ( model, Cmd msg )
    -> Jd.Decoder ( Model model msg, Cmd msg )
modelDecoder updateModel msgDecoder modelCmdPair =
    Jd.map8
        (\( his, cmd ) dbw dbh dlp dtp vph vpw imo ->
            ( { history = his
              , debuggerWidth = dbw
              , debuggerBodyHeight = dbh
              , debuggerLeftPosition = dlp
              , debuggerTopPosition = dtp
              , viewportHeight = vph
              , viewportWidth = vpw
              , isModelOverlayed = imo
              , loadModelError = Nothing
              , mouseEvent = NoEvent
              }
            , cmd
            )
        )
        (Jd.field "history" (History.decoder updateModel msgDecoder modelCmdPair))
        (Jd.field "debuggerWidth" Jd.int)
        (Jd.field "debuggerBodyHeight" Jd.int)
        (Jd.field "debuggerLeftPosition" Jd.int)
        (Jd.field "debuggerTopPosition" Jd.int)
        (Jd.field "viewportHeight" Jd.int)
        (Jd.field "viewportWidth" Jd.int)
        (Jd.field "isModelOverlayed" Jd.bool)



-- Msg


type Msg model msg
    = DoNothing
    | AppMsg msg
    | InitAppMsg msg
    | ViewportResize Int Int
    | ReplayIndex Int
    | ToggleReplay
    | ToggleOverlay
    | HoverElement Elements.HoverTarget
    | SaveModel
    | SelectModel
    | LoadModel File
    | ModelLoaded (Result Jd.Error ( Model model msg, Cmd msg ))
    | CacheModel
    | DragStart Int Int
    | DragMove Int Int
    | DragStop
    | ResetHistory


toMsg : msg -> Msg model msg
toMsg =
    AppMsg


viewportToMsg : Browser.Dom.Viewport -> Msg model msg
viewportToMsg { viewport } =
    ViewportResize (round viewport.width) (round viewport.height)



-- Init


toInit :
    { modelCmdPair : ( model, Cmd msg )
    , msgDecoder : Jd.Decoder msg
    , update : msg -> model -> ( model, Cmd msg )
    , session : Maybe String
    }
    -> ( Model model msg, Cmd (Msg model msg) )
toInit config =
    case config.session of
        Just session ->
            sessionToInit
                config.update
                config.msgDecoder
                config.modelCmdPair
                session

        Nothing ->
            init Nothing config.modelCmdPair


sessionToInit :
    (msg -> model -> ( model, Cmd msg ))
    -> Jd.Decoder msg
    -> ( model, Cmd msg )
    -> String
    -> ( Model model msg, Cmd (Msg model msg) )
sessionToInit update msgDecoder modelCmdPair session =
    case Jd.decodeString (modelDecoder update msgDecoder modelCmdPair) session of
        Ok ( model, cmd ) ->
            ( model
            , Cmd.map InitAppMsg cmd
            )

        Err error ->
            init (Just error) modelCmdPair


init : Maybe Jd.Error -> ( model, Cmd msg ) -> ( Model model msg, Cmd (Msg model msg) )
init loadModelError modelCmdPair =
    let
        ( history, cmd ) =
            History.init modelCmdPair
    in
    ( { history = history
      , debuggerWidth = 200
      , debuggerBodyHeight = 300
      , debuggerLeftPosition = 300
      , debuggerTopPosition = 30
      , viewportHeight = 500
      , viewportWidth = 500
      , isModelOverlayed = False
      , loadModelError = loadModelError
      , mouseEvent = NoEvent
      }
    , Cmd.batch
        [ Cmd.map InitAppMsg cmd
        , Task.perform viewportToMsg Browser.Dom.getViewport
        ]
    )



-- Subs


toSubscriptions :
    { msgDecoder : Jd.Decoder msg
    , subscriptions : model -> Sub msg
    }
    -> Model model msg
    -> Sub (Msg model msg)
toSubscriptions config model =
    Sub.batch
        [ Browser.Events.onResize ViewportResize
        , Time.every 2000 (always CacheModel)
        , replaySubscriptions model.history config.subscriptions
        , dragSubscriptions model.mouseEvent
        ]


replaySubscriptions : History model msg -> (model -> Sub msg) -> Sub (Msg model msg)
replaySubscriptions history subscriptions =
    if History.isReplaying history then
        Sub.none

    else
        Sub.map AppMsg (subscriptions (History.currentModel history))


dragSubscriptions : MouseEvent -> Sub (Msg model msg)
dragSubscriptions event =
    case event of
        Drag _ _ _ _ ->
            Sub.batch
                [ Browser.Events.onMouseUp (Jd.succeed DragStop)
                , Browser.Events.onMouseMove (mousePositionDecoder DragMove)
                ]

        _ ->
            Sub.none


mousePositionDecoder : (Int -> Int -> msg) -> Jd.Decoder msg
mousePositionDecoder msg =
    Jd.map2 msg
        (Jd.field "clientX" Jd.int)
        (Jd.field "clientY" Jd.int)



-- Update


toUpdate :
    { msgDecoder : Jd.Decoder msg
    , encodeMsg : msg -> Je.Value
    , update : msg -> model -> ( model, Cmd msg )
    , output : Je.Value -> Cmd (Msg model msg)
    }
    -> Msg model msg
    -> Model model msg
    -> ( Model model msg, Cmd (Msg model msg) )
toUpdate config msg model =
    case msg of
        DoNothing ->
            ( model, Cmd.none )

        AppMsg appMsg ->
            let
                ( history, cmd ) =
                    History.update config.update appMsg model.history
            in
            ( { model | history = history }, Cmd.map AppMsg cmd )

        InitAppMsg appMsg ->
            let
                ( history, cmd ) =
                    History.updateAndPersist config.update appMsg model.history
            in
            ( { model | history = history }, Cmd.map AppMsg cmd )

        ViewportResize width height ->
            ( { model
                | viewportWidth = width
                , viewportHeight = height
              }
            , Cmd.none
            )

        ReplayIndex index ->
            ( { model | history = History.replay config.update index model.history }
            , Cmd.none
            )

        ToggleReplay ->
            ( { model | history = History.toggleState config.update model.history }
            , Cmd.none
            )

        ToggleOverlay ->
            ( { model | isModelOverlayed = not model.isModelOverlayed }, Cmd.none )

        HoverElement target ->
            case model.mouseEvent of
                Drag _ _ _ _ ->
                    ( model, Cmd.none )

                _ ->
                    ( { model | mouseEvent = Hover target }, Cmd.none )

        SaveModel ->
            ( model
            , File.Download.string
                "devtools-session.json"
                "application/json"
                (Je.encode 0 (encodeModel config.encodeMsg model))
            )

        SelectModel ->
            ( model
            , File.Select.file [ "application/json" ] LoadModel
            )

        LoadModel file ->
            ( model
            , File.toString file
                |> Task.andThen
                    (loadModelHelper config.update
                        config.msgDecoder
                        (History.initialPair model.history)
                    )
                |> Task.attempt ModelLoaded
            )

        ModelLoaded result ->
            case result of
                Ok ( loadedModel, cmd ) ->
                    ( loadedModel, Cmd.map InitAppMsg cmd )

                Err loadError ->
                    ( { model | loadModelError = Just loadError }, Cmd.none )

        CacheModel ->
            ( model, config.output (encodeDevTools config.encodeMsg model) )

        DragStart clickLeft clickTop ->
            ( { model
                | mouseEvent = Drag model.debuggerLeftPosition model.debuggerTopPosition clickLeft clickTop
              }
            , Cmd.none
            )

        DragMove moveLeft moveTop ->
            case model.mouseEvent of
                Drag initLeft initTop clickLeft clickTop ->
                    ( { model
                        | debuggerLeftPosition = initLeft + moveLeft - clickLeft
                        , debuggerTopPosition = initTop + moveTop - clickTop
                      }
                    , Cmd.none
                    )

                Hover _ ->
                    ( model, Cmd.none )

                NoEvent ->
                    ( model, Cmd.none )

        DragStop ->
            ( { model | mouseEvent = NoEvent }, Cmd.none )

        ResetHistory ->
            let
                ( history, cmd ) =
                    History.reset model.history
            in
            ( { model | history = history }, Cmd.map InitAppMsg cmd )


encodeDevTools : (msg -> Je.Value) -> Model model msg -> Je.Value
encodeDevTools encodeMsg model =
    Je.object [ ( "devTools", Je.string (Je.encode 0 (encodeModel encodeMsg model)) ) ]


loadModelHelper :
    (msg -> model -> ( model, Cmd msg ))
    -> Jd.Decoder msg
    -> ( model, Cmd msg )
    -> String
    -> Task Jd.Error ( Model model msg, Cmd msg )
loadModelHelper modelUpdater msgDecoder modelCmdPair string =
    resultToTask (Jd.decodeString (modelDecoder modelUpdater msgDecoder modelCmdPair) string)


resultToTask : Result err ok -> Task err ok
resultToTask result =
    case result of
        Ok value ->
            Task.succeed value

        Err value ->
            Task.fail value



-- View


toDocument :
    { encodeMsg : msg -> Je.Value
    , printModel : model -> String
    , view : model -> Browser.Document msg
    }
    -> Model model msg
    -> Browser.Document (Msg model msg)
toDocument config model =
    let
        { title, body } =
            config.view (History.currentModel model.history)
    in
    { title = title
    , body =
        [ view config model (Html.div [] body)
        ]
    }


toHtml :
    { encodeMsg : msg -> Je.Value
    , printModel : model -> String
    , view : model -> Html msg
    }
    -> Model model msg
    -> Html (Msg model msg)
toHtml config model =
    view config model (config.view (History.currentModel model.history))


view :
    { config
        | encodeMsg : msg -> Je.Value
        , printModel : model -> String
    }
    -> Model model msg
    -> Html msg
    -> Html (Msg model msg)
view config model html =
    Element.layout
        [ Element.inFront
            (Element.el
                [ Element.behindContent
                    (Elements.viewModelOverlay
                        { isEnabled = model.isModelOverlayed
                        , printModel = config.printModel
                        , model = History.currentModel model.history
                        }
                    )
                ]
                (Elements.viewDebugger
                    { width = model.debuggerWidth
                    , bodyHeight = model.debuggerBodyHeight
                    , leftPosition = model.debuggerLeftPosition
                    , topPosition = model.debuggerTopPosition
                    , hoverTarget = toHoverTarget model.mouseEvent
                    , hoverTargetMsg = HoverElement
                    , isModelOverlayed = model.isModelOverlayed
                    , toggleOverlayMsg = ToggleOverlay
                    , isReplaying = History.isReplaying model.history
                    , toggleReplayMsg = ToggleReplay
                    , currentModelIndex = History.currentIndex model.history
                    , modelIndexLength = History.length model.history
                    , changeModelIndexMsg = ReplayIndex
                    , selectModelMsg = SelectModel
                    , loadModelError = model.loadModelError
                    , saveModelMsg = SaveModel
                    , dragStartMsg = DragStart
                    , viewportHeight = model.viewportHeight
                    , viewportWidth = model.viewportWidth
                    , resetHistoryMsg = ResetHistory
                    }
                )
            )
        ]
        (Element.html (Html.map (doNothingOnReplay model.history) html))


doNothingOnReplay : History model msg -> (msg -> Msg model msg)
doNothingOnReplay history =
    if History.isReplaying history then
        always DoNothing

    else
        AppMsg

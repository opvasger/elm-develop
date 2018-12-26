module Debug.Browser.Main exposing
    ( Configuration
    , Program
    , wrapDocument
    , wrapHtml
    , wrapInit
    , wrapMsg
    , wrapSubscriptions
    , wrapUpdate
    )

import Browser
import Debug.Browser.History as History exposing (History)
import Drag
import Html as H exposing (Html)
import Html.Attributes as Ha
import Html.Events as He
import Json.Decode as Jd
import Json.Encode as Je
import Size exposing (Size)
import Task


type alias Configuration appModel appMsg =
    { printModel : appModel -> String
    , encodeMsg : appMsg -> Je.Value
    , msgDecoder : Jd.Decoder appMsg
    , toPort : Je.Value -> Cmd (Msg appMsg)
    }


type alias Program appModel appMsg =
    Platform.Program Jd.Value (Model appModel appMsg) (Msg appMsg)


type alias Model appModel appMsg =
    { history : History appModel appMsg
    , debuggerDrag : Drag.Model
    , viewportSize : Size
    , isModelOverlayed : Bool
    }


type Msg appMsg
    = UpdateApp appMsg
    | ResizeViewport Size
    | DragDebugger Drag.Msg
    | ToggleModelOverlay
    | DoNothing


wrapMsg : (a -> appMsg) -> a -> Msg appMsg
wrapMsg toMsg =
    UpdateApp << toMsg


wrapInit :
    { model : appModel
    , cmds : Cmd appMsg
    , flags : Jd.Value
    , msgDecoder : Jd.Decoder appMsg
    , update : appMsg -> appModel -> ( appModel, Cmd appMsg )
    }
    -> ( Model appModel appMsg, Cmd (Msg appMsg) )
wrapInit config =
    ( { history = History.init config.model
      , debuggerDrag = Drag.init
      , viewportSize = Size 0 0
      , isModelOverlayed = False
      }
    , Cmd.batch
        [ Cmd.map UpdateApp config.cmds
        , Task.perform ResizeViewport Size.getViewportSize
        ]
    )


wrapSubscriptions :
    { msgDecoder : Jd.Decoder appMsg
    , subscriptions : appModel -> Sub appMsg
    }
    -> Model appModel appMsg
    -> Sub (Msg appMsg)
wrapSubscriptions config model =
    Sub.batch
        [ Sub.map UpdateApp (config.subscriptions (History.now model.history))
        , Sub.map DragDebugger (Drag.subscriptions model.debuggerDrag)
        ]


wrapUpdate :
    { msgDecoder : Jd.Decoder appMsg
    , encodeMsg : appMsg -> Je.Value
    , update : appMsg -> appModel -> ( appModel, Cmd appMsg )
    , toPort : Je.Value -> Cmd (Msg appMsg)
    }
    -> Msg appMsg
    -> Model appModel appMsg
    -> ( Model appModel appMsg, Cmd (Msg appMsg) )
wrapUpdate config msg model =
    case msg of
        UpdateApp appMsg ->
            let
                ( appModel, appCmd ) =
                    config.update appMsg (History.now model.history)
            in
            ( { model
                | history = History.insert ( appMsg, appModel ) model.history
              }
            , Cmd.map UpdateApp appCmd
            )

        ResizeViewport viewportSize ->
            ( { model
                | viewportSize = viewportSize
              }
            , Cmd.none
            )

        DragDebugger debuggerDrag ->
            ( { model
                | debuggerDrag = Drag.update debuggerDrag model.debuggerDrag
              }
            , Cmd.none
            )

        ToggleModelOverlay ->
            ( { model
                | isModelOverlayed = not model.isModelOverlayed
              }
            , Cmd.none
            )

        DoNothing ->
            ( model, Cmd.none )


wrapDocument :
    { encodeMsg : appMsg -> Je.Value
    , printModel : appModel -> String
    , view : appModel -> Browser.Document appMsg
    }
    -> Model appModel appMsg
    -> Browser.Document (Msg appMsg)
wrapDocument config appModel =
    let
        { title, body } =
            config.view (History.now appModel.history)
    in
    { title = title
    , body =
        [ view config.printModel appModel (List.map (H.map UpdateApp) body)
        ]
    }


wrapHtml :
    { encodeMsg : appMsg -> Je.Value
    , printModel : appModel -> String
    , view : appModel -> Html appMsg
    }
    -> Model appModel appMsg
    -> Html (Msg appMsg)
wrapHtml config appModel =
    view config.printModel appModel [ H.map UpdateApp (config.view (History.now appModel.history)) ]


view : (appModel -> String) -> Model appModel appMsg -> List (Html (Msg appMsg)) -> Html (Msg appMsg)
view printModel model viewApp =
    viewContainer model.debuggerDrag.isEnabled
        (viewDebugger model.debuggerDrag
            :: viewOverlay printModel model.isModelOverlayed (History.now model.history)
            :: viewApp
        )


viewContainer : Bool -> List (Html (Msg appMsg)) -> Html (Msg appMsg)
viewContainer isDragging =
    H.div []


viewOverlay : (appModel -> String) -> Bool -> appModel -> Html (Msg appMsg)
viewOverlay printModel isModelOverlayed model =
    if isModelOverlayed then
        H.div
            [ Ha.style "top" "0"
            , Ha.style "left" "0"
            , Ha.style "color" "black"
            , Ha.style "padding" "5vw"
            , Ha.style "height" "100vh"
            , Ha.style "position" "fixed"
            , Ha.style "z-index" "2147483646"
            , Ha.style "background-color" "rgba(255,255,255,.95)"
            ]
            [ H.div [] [ H.text (printModel model) ]
            ]

    else
        H.text ""


viewDebugger : Drag.Model -> Html (Msg appMsg)
viewDebugger dragModel =
    H.div
        ([ Ha.style "z-index" "2147483647"
         , Ha.style "font-family" "system-ui"
         , Ha.style "background-color" "white"
         , Ha.style "border" borderStyle
         , onRightClick DoNothing
         ]
            ++ Drag.toFixedPosition dragModel
        )
        [ H.div
            [ Ha.style "border-bottom" borderStyle
            ]
            [ H.button [ He.onClick ToggleModelOverlay ] [ H.text "inspect" ]
            ]
        , H.div [] [ H.text "Page" ]
        , H.div
            [ Ha.style "border-top" borderStyle
            ]
            [ H.button
                [ Drag.onMouseDown DragDebugger
                ]
                [ H.text "drag" ]
            ]
        ]


onRightClick : msg -> H.Attribute msg
onRightClick msg =
    He.preventDefaultOn "contextmenu" (Jd.succeed ( msg, True ))


borderStyle : String
borderStyle =
    "1px solid #d3d3d3"
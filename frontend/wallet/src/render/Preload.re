let downloadRoot = "https://s3-us-west-1.amazonaws.com/proving-key-2018-10-01/";

let downloadKey = (keyName, chunkCb, doneCb) =>
  DownloadLogic.download(
    keyName,
    downloadRoot ++ keyName,
    "binary",
    1,
    chunkCb,
    doneCb,
  );

[@bs.module "electron"] [@bs.scope "shell"] [@bs.val]
external showItemInFolder: string => unit = "";

let showItemInFolder = showItemInFolder;

[@bs.module "electron"] [@bs.scope "shell"] [@bs.val]
external openExternal: string => unit = "";

let openExternal = openExternal;

let isFaker =
  Js.Dict.get(Bindings.ChildProcess.Process.env, "GRAPHQL_BACKEND")
  == Some("faker");

[%bs.raw "window.isFaker = isFaker"];
[%bs.raw "window.downloadKey = downloadKey"];
[%bs.raw "window.showItemInFolder = showItemInFolder"];
[%bs.raw "window.openExternal = openExternal"];
[%bs.raw
  "window.fileRoot = require(\"path\").dirname(window.location.pathname)"
];

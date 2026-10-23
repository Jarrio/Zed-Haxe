package bridge;

import bridge.rpc.Message;
import js.lib.Promise;

/**
	How `Rewrites` talks to both sides. `Bridge` implements it over stdio;
	tests implement it by recording messages.
**/
interface Router {
	function toServer(message:Message):Void;
	function toClient(message:Message):Void;
	function notifyServer(method:String, params:Dynamic):Void;
	function notifyClient(method:String, params:Dynamic):Void;
	function requestServer(method:String, params:Dynamic):Promise<Dynamic>;
	function requestClient(method:String, params:Dynamic):Promise<Dynamic>;

	/** Answers a request that the server sent to Zed, without involving Zed. **/
	function replyToServer(id:Dynamic, result:Dynamic):Void;

	/** Answers a request that Zed sent to the server, without involving the server. **/
	function replyToClient(id:Dynamic, result:Dynamic):Void;
}

/**
 * | <a href="index.html">Home</a>             | <a href="server.html">Server</a>              |
 *   <a href="client.html">Client</a>          | <a href="router.html">Router</a>              |
 *   <a href="cgi.html">CGI</a>                | <a href="filebuffer.html">File Buffer</a>     |
 *   <a href="structs.html">Structures</a>     | <a href="helper.html">Helper functions</a>    |
 *
 * License: Use freely for any purpose
 */
module danode.structs;

import std.stdio, std.string, std.socket, std.datetime, std.file, std.uri, std.random, std.conv;
import danode.helper , danode.client, danode.jobrunner, danode.filebuffer, danode.mimetypes, danode.https;

immutable string      SERVER_INFO      = "DaNode/0.0.1 (Universal)";                /// Server identification info
immutable string      MPHEADER         = "multipart/form-data";                     /// Multipart header id
immutable string      XFORMHEADER      = "application/x-www-form-urlencoded";       /// X-form header id
immutable string      MPDESCR          = "Content-Disposition: form-data; name=\""; /// Multipart description
immutable string      UNSUPPORTED_FILE = "file/unknown";                            /// Unsupported file mime
immutable string      CGI_FILE         = "cgi/";                                    /// CGI mime prefix
immutable size_t      KBYTE            = 1_024;                                     /// 1024
immutable size_t      MBYTE            = 1_048_576;
immutable size_t      BUFFERSIZE       = 24*KBYTE;    /// Size of Most buffers used
immutable size_t      MAX_SEND_ERRORS  = 5_000_000;   /// Maximum number of errors before we stop sending
immutable size_t[3]   TIMEOUT          = [5, 3, 10];  /// Different timeouts in seconds
immutable size_t      MAX_CONNECTIONS  = 300;         /// Maximum connection before we start dropping new ones
immutable string      UPLOADDIR        = "uploads/";        /// Global folder for all initial file uploads
immutable string[]    DEFAULTINDICES   = ["index.php", "index.d", "index.cgi", "index.pl",
                                           "index.py", "index.r", "index.html", "index.htm"];
immutable bool        LOGENABLED       = false;

immutable string BLACK = "\x1B[30m", RED = "\x1B[31m", GREEN = "\x1B[32m", YELLOW = "\x1B[33m",
                 BLUE = "\x1B[34m", MAGENTA = "\x1B[35m",CYAN = "\x1B[36m", WHITE = "\x1B[37m";

string doColor(string text, string color = GREEN){ return color ~ text ~ WHITE; }

immutable string 
  timeFmt =  "%s %s %s %s:%s:%s %s",
  okPFmt  =  "%s %s (%s) to %s:%s, code: %s [%s msecs]",
  errPFmt =  "Error: %s to %s:%s, code: %s [%s msecs]",
  errFmt  =  "<html>\n  <head>\n    <title>%s - %s</title>\n  </head>\n  <body>\n    <h2>%s</h2>\n"~
             "    There was a problem with the requested URL: %s\n    <hr>Additional:<br>\n    %s\n" ~
             "    <hr>Error page generated by %s\n  </body>\n</html>",
  errPageFmt = "Failed:<font color='orange'> %s < %s</font><br><hr>STDERR:<br><font color='red'>%s</font>",
  serverArgsFmt = 
 "SERVER=SERVER_SOFTWARE=%s\nSERVER=GATEWAY_INTERFACE=CGI/1.1\nSERVER=SERVER_NAME=%s\nSERVER=SERVER_ADDR=\n" ~
 "SERVER=SERVER_PROTOCOL=%s\nSERVER=REMOTE_ADDR=%s\nSERVER=REMOTE_PORT=%s\nSERVER=REQUEST_METHOD=%s\n" ~
 "SERVER=REQUEST_URI=%s\nSERVER=SCRIPT_FILENAME=%s\nSERVER=HTTP_ACCEPT=%s",
  headerFMT = "HTTP/1.1 %s %s\r\nServer: %s\r\nX-Powered-By: %s %s.%s\r\nConnection: %s\r\n"~ 
              "Content-Type: %s; charset=%s\r\nContent-Length: %s\r\n";
string[int] months;
static this(){   months = [ 1: "Jan", 2: "Feb", 3: "Mar", 4 : "Apr", 5 : "May", 6 : "Jun", 
                            7: "Jul", 8: "Aug", 9: "Sep", 10: "Oct", 11: "Nov", 12: "Dec"]; }
immutable size_t CONNECTED = 0, MODIFIED = 1, FORCGI = 2;

alias core.thread.Thread.sleep  Sleep;
alias Clock.currTime            now;
alias std.string.split          strsplit;
alias std.array.replace         strrepl;
alias std.file.read             fileread;
alias void function(ref Job)    JobFunc;

/***********************************
 * Structure to hold server statistics
 */
struct ServerStat{
  int nconnections = 0;             /// Number of connections
  int ntoobusy     = 0;             /// Number of connections dropped because we were too busy
  int ntimedout    = 0;             /// Number of connections that timed out
  int[string][string][string] log;  /// Three dimensional server log
}

/***********************************
 * Structure to hold server information
 */
struct Server{
  ushort       port    = 80;        /// Port the server listen on
  uint         backlog = 100;       /// Backlog of clients
  Socket       socket;              /// Server socket on port
  version(SSL){
    Context      SSL;               /// SSL context
    HTTPS        https;             /// HTTPS server socket
  }
  SocketSet    set;                 /// Socket listening set
  ServerStat   stats;               /// Statistics
  FileBuffer   filebuffer;          /// FileBuffer for small files
  Client[]     clients;             /// Active client array

  void addClient(Client client){ this.clients ~= client; }

  uint         verbose = 0;         /// Verbose switch
}

/***********************************
 * Structure representing a HTTP Request
 */
struct Request{
  string          method = "GET";               /// The request method
  string          user;                         /// Username from url authentication
  string          pass;                         /// Password from url authentication
  string          scheme = "HTTP";              /// Scheme requested
  string          domain = "";                  /// Domain requested
  int             port = 80;                    /// Port at which the request was targetted
  string          path = "/";                   /// Requested path
  string          query = "";                   /// Query string
  string          protocol  = "HTTP/1.1";       /// Protocol requested
  string[string]  headers;                      /// Additional headers
  string          multipartid;                  /// MultipartID (if any)
  string[]        files;                        /// String paths of files used by POST and File upload
  string          cgicmd;                       /// The CGI command executed

  @property string[string]  GET(){
    string[string] params;
    foreach(param; strsplit(query, "&")){
      string[] gv = param.strsplit("=");
      if(gv.length == 1) gv ~= "TRUE";
      params[gv[0]] = gv[1];
    }
    return params;
  }

  string url(){ return format("%s://%s:%d%s?%s", scheme, domain, port, path, query); }
  @property string shortname(){ return format("%s %s%s?%s",method, domain, path, query); }
  @property string shorturl(){ return format("%s://%s:%d%s",scheme, domain, port, path); }
  @property string printmpid(){ return multipartid[(multipartid.lastIndexOf("-")+1) .. $]; }
  @property string endmpid(){ return multipartid ~ "--"; }
}

enum PayLoadType { NONE = -1, STRING = 0, FILE = 1, PIPE = 2 };

/***********************************
 * Payload structure used to send response data to the Client
 */
struct PayLoad{
  string      content;                      /// The file content or filepath
  PayLoadType type = PayLoadType.STRING;    /// The type of payload to send
  size_t      size = 0;                     /// When PIPE, this is used to record the size send
  alias       content this;                 /// Use an alias so payload acts like a string
  @property const size_t length(){          /// Overwite length so we can use contentlength = payload.length
    final switch(type){
      case PayLoadType.STRING: return content.length;
      case PayLoadType.FILE:   return to!size_t(getSize(content));
      case PayLoadType.PIPE:   return size;
      case PayLoadType.NONE:   return 0;
    }
  }
}

immutable PayLoad EMPTYPAYLOAD = PayLoad(null, PayLoadType.NONE, 0);

/***********************************
 * HTTP Response structure
 */
struct Response{
  uint            code       = 200;             /// Response code
  string          reason     = "OK";            /// Reason
  PayLoad         payload    = EMPTYPAYLOAD;    /// PayLoad to send back
  string          protocol   = "HTTP/1.1";      /// Protocol to use
  string          mime       = "text/plain";    /// Mime type of the response
  string          charset    = "utf-8";         /// Character set used in the response
  SysTime         date       = SysTime.init;    /// Time of the response
  bool            keepalive  = false;           /// Should we keep the connection open ?
  bool            headeronly = false;           /// Set to true when only a HTTP header is required
  bool            bodyonly   = false;           /// Does the Server generate the HTTP header
  string[string]  headers    = null;            /// Additional HTTP headers
  const string toString(Client client){
    string cstr     = format("%s", code);
    string sslstat  = "]  ";
    version(SSL){ 
      sslstat = (client.isSSL? doColor(" ⬤"): doColor(" ✖", RED)) ~ "]";
    }
    if(code < 400) cstr = doColor(cstr, GREEN);
    if(code == 400) cstr = doColor(cstr, YELLOW);
    if(code > 400) cstr = doColor(cstr, RED);
    return(format("[%s%s  %s %s %.2f kB", cstr, sslstat, reason, protocol, payload.length / 1024.0f));
  }
}

/***********************************
 * Internal structure used by FileBuffer
 */
struct BFile{
  void[]   content;  /// Raw file content
  string   mime;     /// Mime type of the content
  SysTime  btime;    /// Time when the file was buffered
}

struct Job{
  long      id;
  string    name;
  string    owner     = "system";
  long      period    = 1000;
  long      times     = -1;
  long      executed  = 0;
  SysTime   t0;
  JobFunc   task;

  @property long   age(){ return(Msecs(t0)); }
  @property string asitem(){ return format("<li>%s - %s [%s] (%s/%s)</li>", id, name, owner, executed, times); }
}


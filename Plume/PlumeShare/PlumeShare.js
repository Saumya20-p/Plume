var PlumeShare = function() {};
PlumeShare.prototype = {
    run: function(arguments) {
        arguments.completionFunction({
            "url": document.URL,
            "html": document.documentElement.outerHTML
        });
    }
};
var ExtensionPreprocessingJS = new PlumeShare;

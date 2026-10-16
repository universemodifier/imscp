/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

window.confirm = (function () {
    var native = window.confirm;
    return function (msg, callback) {
        ($.imscp && $.isFunction($.imscp.confirm)) ? $.imscp.confirm(msg, callback) : callback(native(msg));
    }
})();

function flashMessage(type, message) {
    $(".flash_message").remove();
    $("<div>", {"class": "flash_message " + type, "html": $.parseHTML(message)}).prependTo(".body").trigger("message_timeout");
}

function doRequest($form, action, postURL) {
    var formData = $form.serializeArray();
    formData.push({name: "letsencrypt_action", value: action});
    return $.post(postURL, formData, null, "json");
}

function handleResponse(jqXHR, postURL, forbiddenRedirectURL) {
    jqXHR.then(
        function () {
            window.location.replace(postURL);
        },
        function () {
            if (jqXHR.status === 403) {
                window.location.replace(forbiddenRedirectURL);
                return;
            }

            flashMessage("error", jqXHR.responseJSON.message);
        }
    );

    return jqXHR;
}

function initDialogForDNSnamesEdit($dialog) {
    var DNSnames = $dialog.find('textarea:first').val();
    $dialog.on("dialogclose", function () {
        $dialog.find('textarea:first').val(DNSnames);
    }).on("keyup", "textarea", {dialog: $dialog}, $.debounce(300, function (e) {
        if ($.trim($(this).val()) !== DNSnames) {
            e.data.dialog.dialog("widget").find(".apply_changes_button:hidden").show();
        } else {
            e.data.dialog.dialog("widget").find(".apply_changes_button:visible").hide();
        }
    }));
}

<?php
/**
 * i-MSCP LetsEncrypt plugin
 *
 * @author        Laurent Declercq <l.declercq@nuxwin.com>
 * @copyright (C) 2016-2018 Laurent Declercq <l.declercq@nuxwin.com>
 * @license       i-MSCP License <http://www.i-mscp.net/license-agreement.html>
 */

namespace ImscpLetsEncrypt;

/**
 * Class JsonResponse
 * @package ImscpLetsEncrypt
 */
final class JsonResponse
{
    /**
     * @var array 
     */
    private $data = [];

    /**
     * @var int
     */
    private $statusCode;

    /**
     * ResponseJson constructor.
     *
     * @param int $statusCode
     * @param array $data
     */
    public function __construct($statusCode = 200, array $data = [])
    {
        $this->validateStatusCode($statusCode);

        $this->statusCode = $statusCode;
        $this->data = $data;
    }

    /**
     * Send response
     *
     * @return void;
     */
    public function sendResponse()
    {
        echo $this->prepareResponse();
        exit;
    }

    /**
     * Prepare response
     *
     * @return string
     */
    public function prepareResponse()
    {
        header('Cache-Control: no-cache, must-revalidate');
        header('Expires: Mon, 26 Jul 1997 05:00:00 GMT');
        header('Content-type: application/json');

        switch ($this->statusCode) {
            case 400:
                header('Status: 400 Bad Request');
                break;
            case 404:
                header('Status: 404 Not Found');
                break;
            case 409:
                header('Status: 409 Conflict');
                break;
            case 422:
                header('Status: 422 Unprocessable Entity');
                break;
            case 500:
                header('Status: 500 Internal Server Error');
                break;
            case 501:
                header('Status: 501 Not Implemented');
                break;
            default:
                header('Status: 200 OK');
        }

        return json_encode($this->data);
    }

    /**
     * Return string representation of this JSON response
     *
     * @return string
     */
    public function __toString()
    {
        return $this->prepareResponse();
    }

    /**
     * Validate the given status code
     * @param $statusCode
     */
    protected function validateStatusCode($statusCode)
    {
        if (!in_array($statusCode, [200, 400, 404, 409, 422, 500, 501])) {
            throw new \InvalidArgumentException('Invalid status code');
        }
    }
}

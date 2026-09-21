// SAML callback server for the AWS Client VPN SAML flow.
//
// Vendored from https://github.com/samm-git/aws-vpn-client (server.go) and
// adapted: the SAML POST body is written to the path given by the
// SAML_RESPONSE_PATH environment variable instead of the process's current
// working directory, so the connect wrapper can place it in a private temp dir.
package main

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
)

func samlResponsePath() string {
	if p := os.Getenv("SAML_RESPONSE_PATH"); p != "" {
		return p
	}
	return "saml-response.txt"
}

func main() {
	http.HandleFunc("/", SAMLServer)
	log.Printf("Starting HTTP server at 127.0.0.1:35001")
	if err := http.ListenAndServe("127.0.0.1:35001", nil); err != nil {
		log.Fatal(err)
	}
}

func SAMLServer(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "POST":
		if err := r.ParseForm(); err != nil {
			fmt.Fprintf(w, "ParseForm() err: %v", err)
			return
		}
		SAMLResponse := r.FormValue("SAMLResponse")
		if len(SAMLResponse) == 0 {
			log.Printf("SAMLResponse field is empty or not exists")
			return
		}
		if err := os.WriteFile(samlResponsePath(), []byte(url.QueryEscape(SAMLResponse)), 0600); err != nil {
			log.Printf("failed to write SAML response: %v", err)
			fmt.Fprintf(w, "Error writing SAML response: %v", err)
			return
		}
		fmt.Fprintf(w, "Got SAMLResponse field, it is now safe to close this window\n")
		log.Printf("Got SAMLResponse field and saved it")
		return
	default:
		fmt.Fprintf(w, "Error: POST method expected, %s received", r.Method)
	}
}

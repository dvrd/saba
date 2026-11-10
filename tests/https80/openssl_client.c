/* Independent OpenSSL HTTPS verifier. Keys/anchors are public test fixtures. */
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void require(int ok,const char *why) {
 if(!ok) {fprintf(stderr,"FAIL %s\n",why);ERR_print_errors_fp(stderr);exit(1);}
}
int main(int argc,char **argv) {
 require(argc==4,"endpoint CA mode");const char *mode=argv[3];
 int expected=X509_V_OK;
 if(!strcmp(mode,"hostname"))expected=X509_V_ERR_HOSTNAME_MISMATCH;
 if(!strcmp(mode,"expired"))expected=X509_V_ERR_CERT_HAS_EXPIRED;
 if(!strcmp(mode,"before"))expected=X509_V_ERR_CERT_NOT_YET_VALID;
 if(!strcmp(mode,"trust"))expected=X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT;
 SSL_CTX *ctx=SSL_CTX_new(TLS_client_method());require(ctx!=NULL,"TLS context");
 require(SSL_CTX_set_min_proto_version(ctx,TLS1_3_VERSION),"minimum TLS1.3");
 require(SSL_CTX_set_max_proto_version(ctx,TLS1_3_VERSION),"maximum TLS1.3");
 require(SSL_CTX_set_ciphersuites(ctx,"TLS_AES_128_GCM_SHA256"),"cipher suite");
 SSL_CTX_set_verify(ctx,SSL_VERIFY_PEER,NULL);
 require(SSL_CTX_load_verify_locations(ctx,argv[2],NULL),"explicit test anchor");
 X509_VERIFY_PARAM_set_time(SSL_CTX_get0_param(ctx),!strcmp(mode,"expired")?2000000000:(!strcmp(mode,"before")?0:1790000000));
 const unsigned char offer[]={8,'h','t','t','p','/','1','.','1'};
 require(SSL_CTX_set_alpn_protos(ctx,offer,sizeof offer)==0,"ALPN offer");
 BIO *bio=BIO_new_ssl_connect(ctx);require(bio!=NULL,"connection BIO");
 SSL *ssl=NULL;BIO_get_ssl(bio,&ssl);require(ssl!=NULL,"SSL handle");
 require(SSL_set_tlsext_host_name(ssl,"synthetic.invalid"),"SNI");
 require(X509_VERIFY_PARAM_set1_host(SSL_get0_param(ssl),!strcmp(mode,"hostname")?"wrong.invalid":"synthetic.invalid",0),"hostname policy");
 require(BIO_set_conn_hostname(bio,argv[1]),"loopback endpoint");
 int connected=BIO_do_connect(bio)>0&&BIO_do_handshake(bio)>0;
 if(expected!=X509_V_OK) {
  require(!connected&&SSL_get_verify_result(ssl)==expected,"exact independent certificate rejection");
  printf("{\"passed\":true,\"mode\":\"%s\",\"verify_code\":%d}\n",mode,expected);
  BIO_free_all(bio);SSL_CTX_free(ctx);return 0;
 }
 require(connected&&SSL_get_verify_result(ssl)==X509_V_OK,"trusted handshake");
 const unsigned char *protocol=NULL;unsigned int size=0;SSL_get0_alpn_selected(ssl,&protocol,&size);
 require(size==8&&!memcmp(protocol,"http/1.1",8),"negotiated http/1.1");
 const char *request="GET /close HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: close\r\n\r\n";
 size_t written=0;require(SSL_write_ex(ssl,request,strlen(request),&written)&&written==strlen(request),"HTTP request");
 unsigned char buffer[16384];size_t used=0,count=0;
 for(;;) {
  require(used<sizeof(buffer)-1,"bounded response");
  int received=SSL_read_ex(ssl,buffer+used,sizeof(buffer)-1-used,&count);
  if(!received) {require(SSL_get_error(ssl,received)==SSL_ERROR_ZERO_RETURN,"authenticated TLS close_notify");break;}
  used+=count;
 }
 buffer[used]=0;require(!strncmp((char *)buffer,"HTTP/1.1 200 ",13),"HTTP status");
 char *body=strstr((char *)buffer,"\r\n\r\n");require(body!=NULL&&!strcmp(body+4,"https80-ok\n"),"exact HTTP body");
 (void)SSL_shutdown(ssl);BIO_free_all(bio);SSL_CTX_free(ctx);
 printf("{\"passed\":true,\"mode\":\"trusted\",\"close_notify\":true}\n");return 0;
}

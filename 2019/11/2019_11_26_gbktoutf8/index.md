# 编码 Gbk To Utf8 


通常爬取某个网页中，发现网页编码并不是 [utf8](<https://baike.baidu.com/item/UTF-8?fromtitle=UTF8&fromid=772139>) 而是 [gbk](<https://baike.baidu.com/item/GBK%E5%AD%97%E5%BA%93/3910360?fromtitle=GBK&fromi d=481954&fr=aladdin>) 。

而golang有两种方法可以解决

+ <https://github.com/axgle/mahonia>

  ```go
  package main
  
  import (
      "fmt"
      "github.com/axgle/mahonia"
  )
  func main(){
    src:="编码转换内容内容"
    enc := mahonia.NewEncoder("gbk")
    // converts a  string from UTF-8 to gbk encoding.
    fmt.Println(enc.ConvertString(src)) 
  }
  ```

  

+ <https://godoc.org/golang.org/x/text/encoding/simplifiedchinese>

  ```go
  package main
  
  import (
      "bytes"
      "fmt"
      "golang.org/x/text/encoding/simplifiedchinese"
      "golang.org/x/text/transform"
      "io/ioutil"
  )
  func main() {
      src:="编码转换内容内容"
      data, _ := ioutil.ReadAll(transform.NewReader(bytes.NewReader([]byte(src)), simplifiedchinese.GBK.NewEncoder()))
      fmt.Println(data) //byte
      fmt.Println(string(data))  //打印为乱码
      // convert a string from UTF-8 to gbk encoding.
  }
  ```

而想要从GBK转UTF-8需要decode函数。



##### 实例

问题： 获取百度页面数据，关于中文部分总数乱码，需要转换成UTF-8格式的中文字符

```go
package main

import (
	"bytes"
	"fmt"
	"github.com/axgle/mahonia"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
	"io/ioutil"
	"net/http"
	"regexp"
)

func main() {
	resp,err := http.Get("http://top.baidu.com/buzz?b=341&c=513&fr=topbuzz_b1")
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()
	bts,err := ioutil.ReadAll(resp.Body)
	if err != nil {
		panic(err)
	}

	regx,err := regexp.Compile(`<a class=.*</a>`)
	if err != nil {
		panic(err)
	}

	text := regx.FindString(string(bts))
	fmt.Println("原文：",text)

	// 1、
	dec := mahonia.NewDecoder("gbk")
	fmt.Println("mahonia包:",dec.ConvertString(text))

	// 2、
	data,_ := ioutil.ReadAll(transform.NewReader(bytes.NewReader([]byte(text)),simplifiedchinese.GBK.NewDecoder()))
	fmt.Println("官方包:",string(data))
}


```

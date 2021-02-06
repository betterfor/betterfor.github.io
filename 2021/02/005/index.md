# LEETCODE 005. 最长回文串


> 力扣百题系列

大家好，我是小耗。

今天给大家带来的是经典题之回文串。

什么是回文串？正着读和反着读都是一样的字符串就是回文串，例如`level`。

## 题目

给一个字符串`s`，找出`s`中最长的回文子串。

## 题解

1、暴力法

判断一个字符串是否是回文串，然后再找出所有的回文子串。

```go
func longestPalindrome(s string) string {
 	var maxLen int
 	var maxStr string
 	for i := 0; i < len(s); i++ {
 		for j := i + 1; j < len(s)+1; j++ {
 			len := isPalindrome(s[i:j])
 			if len > maxLen {
 				maxStr = s[i:j]
 				maxLen = len
 			}
 		}
 	}
 	return maxStr
 }
 
 func isPalindrome(s string) int {
 	var newStr string
 	for i := len(s)-1; i >= 0; i--{
 		newStr += s[i:i+1]
 	}
 	if s == newStr {
 		return len(s)
 	}
 	return 0
 }
```

时间复杂度O(n^3^)，空间复杂度O(1)。

很显然，这种方法效率极低。

2、动态规划

对于一个字符串而言，如果它是回文串，那么它去掉首尾，仍会是回文串，

即字符串`P`是回文子串，那么`P(i,j)=P(i+1,j-1)`且`S[i]=S[j]`。

```go
func longestPalindrome(s string) (ans string) {
	n := len(s)
	dp := make([][]int, n)
	for i := 0; i < n; i++ {
		dp[i] = make([]int, n)
	}
    // 从长度较短的字符串向长度较长的字符串转移
	for length := 0; length < n; length++ {
		for i := 0; i+length < n; i++ {
			j := i + length
			if length == 0 {
				dp[i][j] = 1
			} else if length == 1 {
				if s[i] == s[j] {
					dp[i][j] = 1
				}
			} else {
				if s[i] == s[j] {
					dp[i][j] = dp[i+1][j-1]
				}
			}
			if dp[i][j] > 0 && length+1 > len(ans) {
				ans = s[i : i+length+1]
			}
		}
	}
	return ans
}
```

时间复杂度O(n^2^)，空间复杂度O(n^2^)。

3、中心扩展

根据方法二，我们可以得到字符串是向外扩展的，从`P(i+1,j-1)`向`P(i,j)`，如果两边字母不同，我们就可以停止扩展。

```go
func longestPalindrome(s string) string {
	if len(s) == 0 {
		return ""
	}
	var start, end int
	for i := 0; i < len(s); i++ {
		l1, r1 := expandStr(s, i, i)   // 奇
		l2, r2 := expandStr(s, i, i+1) // 偶
		if r1-l1 > end-start {
			start, end = l1, r1
		}
		if r2-l2 > end-start {
			start, end = l2, r2
		}
	}
	return s[start : end+1]
}

func expandStr(s string, left, right int) (int, int) {
	for ; left >= 0 && right < len(s) && s[left] == s[right]; left, right = left-1, right+1 {}
	return left + 1, right - 1
}
```

时间复杂度O(n^2^)，空间复杂度O(1)

4、Manacher算法（马拉车算法）

Manacher 算法用来查找一个字符串中的最长回文子串的线性算法。

由于回文分为偶回文`(baab)`和奇回文`(aba)`，所以Manacher算法采用的方法是插入符号。

Manacher=动态规划+中心扩展

- 在字符串的首尾及每个字符都插入一个`#`，这样原先的奇偶回文都会变成奇回文

```go
func longestPalindrome(s string) string {
    start, end := 0, -1
    t := "#"
    for i := 0; i < len(s); i++ {
        t += string(s[i]) + "#"
    }
    t += "#"
    s = t
    arm_len := []int{}
    right, j := -1, -1
    for i := 0; i < len(s); i++ {
        var cur_arm_len int
        if right >= i {
            i_sym := j * 2 - i
            min_arm_len := min(arm_len[i_sym], right-i)
            cur_arm_len = expand(s, i-min_arm_len, i+min_arm_len)
        } else {
            cur_arm_len = expand(s, i, i)
        }
        arm_len = append(arm_len, cur_arm_len)
        if i + cur_arm_len > right {
            j = i
            right = i + cur_arm_len
        }
        if cur_arm_len * 2 + 1 > end - start {
            start = i - cur_arm_len
            end = i + cur_arm_len
        }
    }
    ans := ""
    for i := start; i <= end; i++ {
        if s[i] != '#' {
            ans += string(s[i])
        }
    }
    return ans
}

func expand(s string, left, right int) int {
    for ; left >= 0 && right < len(s) && s[left] == s[right]; left, right = left-1, right+1 { }
    return (right - left - 2) / 2
}

func min(x, y int) int {
    if x < y {
        return x
    }
    return y
}
```

时间复杂度O(n)，空间复杂度O(n)
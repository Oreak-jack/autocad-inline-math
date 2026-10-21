;; Put the extracted CadMath03.bundle in C:/CadMath03/.
;; If using another folder, change only the path below (use forward slashes).
((lambda (/ dll)
  (setq dll "C:/CadMath03/CadMath03.bundle/Contents/Win64/CadMath03.dll")
  (if (findfile dll)
    (command "_.NETLOAD" dll)
    (princ "\nCadMath03: DLL not found. Check the path in CadMath03-Startup.lsp.")
  )
))
(princ)
